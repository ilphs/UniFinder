import AppKit
import Foundation
import Observation
import OSLog

/// 업데이트 확인의 상태 기계 (후속 T3 / UI설계 §7.9).
///
/// `AppEnvironment`가 소유하는 **앱 전역 1개** 인스턴스다 — 창마다 확인하면 앱을 켤 때
/// 창 수만큼 요청이 나가고 알림도 창 수만큼 뜬다. 알림을 실제로 그리는 창은 하나로 게이팅한다
/// (`AppEnvironment.globalAlertPresenterID` — FDA 온보딩 시트와 같은 승계 규칙).
///
/// **자동 확인과 수동 확인은 실패 처리가 다르다**(D4):
/// - 자동: 실패를 **완전히 침묵**한다(로그만). 이 앱은 애초에 네트워크 앱이 아니므로(설계서 §1.2)
///   오프라인 사용자가 앱을 켤 때마다 알림을 받는 것은 명백한 퇴보다.
/// - 수동: 사용자가 요청한 조작이므로 결과를 **반드시** 말한다(성공·최신·실패 모두).
@Observable
@MainActor
final class UpdateCheckModel {

    /// 화면에 띄울 결과 1건. `nil`이면 아무것도 띄우지 않는다.
    enum Presentation: Equatable, Identifiable {
        case available(UpdateRelease, current: SemanticVersion)
        case upToDate(current: SemanticVersion)
        case failed(message: String)

        var id: String {
            switch self {
            case let .available(release, _): return "available-\(release.version)"
            case let .upToDate(current): return "uptodate-\(current)"
            case let .failed(message): return "failed-\(message)"
            }
        }
    }

    /// 지금 띄워야 하는 결과. 뷰가 `.alert`로 소비하고 닫을 때 `nil`로 되돌린다.
    var presentation: Presentation?

    /// 확인이 진행 중인지. **Help 메뉴가 이 값을 읽어** 항목 제목을 바꾸고 비활성화한다
    /// (`CheckForUpdatesButton` — reviewer minor #10). 확인은 최대 10초까지 걸릴 수 있어,
    /// 표시가 없으면 사용자는 메뉴가 먹통이 된 것으로 오인하고 같은 항목을 반복해서 누른다.
    ///
    /// **예전에는 아무도 읽지 않는 값이었다.** 되살릴 때 함께 지켜야 하는 규칙:
    /// 시작에서 `true`, 끝나는 모든 경로(성공·실패·취소)에서 `false`여야 한다.
    private(set) var isChecking = false

    // `latestKnownVersion`은 제거했다(reviewer minor #10): 어디에서도 읽지 않는 값이었고,
    // 같은 사실을 `preferences.cachedLatestVersion`이 이미 들고 있다(그쪽은 304 판정에 실제로 쓰이고
    // 실행 사이에도 남는다). 표시가 필요해지면 그 값을 읽으면 된다 — 사본을 둘 이유가 없다.

    let preferences: UpdatePreferences

    @ObservationIgnored
    private let checker: UpdateChecker

    /// 현재 앱 버전. 기본값은 `AppVersion` — **버전 리터럴을 여기에 두지 않는다**(T0).
    @ObservationIgnored
    private let currentVersion: SemanticVersion

    /// 브라우저 열기 주입점 (`FullDiskAccessModel.opener` 선례) — 테스트가 실제 브라우저를 띄우지 않게 한다.
    @ObservationIgnored
    private let opener: @MainActor (URL) -> Bool

    /// 시계 주입점 — 24시간 스로틀을 테스트가 결정적으로 검증한다.
    @ObservationIgnored
    private let now: @Sendable () -> Date

    @ObservationIgnored
    private var checkTask: Task<Void, Never>?

    /// 확인 시도의 세대 번호 — 취소된 이전 시도가 `isChecking`을 되돌리지 못하게 막는다.
    @ObservationIgnored
    private var checkGeneration = 0

    /// 프로세스당 1회만 도는 시작 확인을 위한 래치.
    @ObservationIgnored
    private var didRunLaunchCheck = false

    @ObservationIgnored
    private let log = Logger(subsystem: "com.unifinder.app", category: "update")

    init(
        preferences: UpdatePreferences? = nil,
        checker: UpdateChecker = UpdateChecker(),
        currentVersion: SemanticVersion? = nil,
        opener: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.preferences = preferences ?? UpdatePreferences()
        self.checker = checker
        self.currentVersion = currentVersion ?? AppVersion.currentSemantic
        self.opener = opener
        self.now = now
    }

    deinit {
        checkTask?.cancel()
    }

    // MARK: - 진입점

    /// 앱 시작 시 1회 (창이 열릴 때 호출되지만 **프로세스당 한 번만** 실제로 돈다).
    /// 자동 확인이 꺼져 있거나 24시간이 지나지 않았으면 아무 일도 하지 않는다.
    /// - Returns: 실제로 확인을 시작했으면 `true`(테스트가 스로틀을 관찰하는 지점).
    @discardableResult
    func checkOnLaunchIfNeeded() -> Bool {
        guard !didRunLaunchCheck else { return false }
        didRunLaunchCheck = true
        guard preferences.shouldAutoCheck(now: now()) else { return false }
        start(manual: false)
        return true
    }

    /// Help > Check for Updates… — **스로틀을 무시**하고 항상 확인하며, 결과를 항상 말한다.
    func checkManually() {
        start(manual: true)
    }

    /// 진행 중인 확인 작업이 있으면 기다린다(테스트 지원).
    func waitForCurrentCheck() async {
        await checkTask?.value
    }

    private func start(manual: Bool) {
        // 확인이 겹치면 나중 것이 이긴다 — 사용자가 메뉴를 두 번 눌렀을 때 알림이 두 번 뜨지 않게.
        checkTask?.cancel()
        // **세대 번호**를 함께 올린다: 취소된 이전 Task도 `defer`를 지나가므로, 세대 확인 없이
        // `isChecking = false`를 쓰면 방금 시작한 확인이 진행 중인데 메뉴가 "끝났다"고 표시한다.
        checkGeneration &+= 1
        let generation = checkGeneration
        isChecking = true
        let etag = preferences.cachedETag
        let checker = self.checker
        checkTask = Task { @MainActor [weak self] in
            defer { self?.finishChecking(generation) }
            do {
                let result = try await checker.fetchLatestRelease(etag: etag)
                guard let self, !Task.isCancelled else { return }
                self.apply(result, manual: manual)
            } catch is CancellationError {
                return
            } catch let error as UpdateCheckError {
                guard let self, !Task.isCancelled else { return }
                self.handle(error, manual: manual)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.handle(.transport(error.localizedDescription), manual: manual)
            }
        }
    }

    /// 확인 1건의 종료 처리 — **가장 최근에 시작한 확인만** 진행 표시를 내린다.
    private func finishChecking(_ generation: Int) {
        guard generation == checkGeneration else { return }
        isChecking = false
    }

    // MARK: - 결과 반영

    private func apply(_ result: UpdateCheckResult, manual: Bool) {
        // 성공한 확인만 스로틀 시각을 갱신한다 — 실패가 갱신하면 잠깐 끊긴 사용자가
        // 그 뒤 24시간 동안 자동 확인을 통째로 잃는다.
        preferences.lastCheckedAt = now()
        if let etag = result.etag { preferences.cachedETag = etag }

        switch result.response {
        case let .release(release):
            preferences.cachedLatestVersion = release.version.description
            present(release: release, manual: manual)

        case .notModified:
            // 304 — 본문이 없다. 캐시된 버전으로 같은 판정을 내린다.
            let cached = preferences.cachedLatestVersion.flatMap(SemanticVersion.init)
            if let cached, cached > currentVersion {
                // 릴리스 노트를 다시 받지 않았으므로 노트 없이 안내한다.
                // 페이지 주소는 이제 **옵셔널**이다(reviewer minor #1) — 만들 수 없으면
                // [Download]가 열 곳이 없다. 그 상태에서 "새 버전이 있다"만 띄우면 막다른 길이므로
                // 수동 확인에는 실패로 답한다(저장소 이름이 이상할 때만 닿는 경로다 —
                // 그런 설정이면 조회 자체가 `invalidRepository`로 끝나 여기까지 오지 않는다).
                guard let pageURL = checker.releasesPageURL else {
                    if manual { presentation = .failed(message: UpdateCheckError.invalidRepository.message) }
                    return
                }
                let release = UpdateRelease(
                    version: cached,
                    tagName: cached.description,
                    title: "UniFinder \(cached)",
                    notes: "",
                    pageURL: pageURL
                )
                present(release: release, manual: manual)
            } else if manual {
                presentation = .upToDate(current: currentVersion)
            }

        case .noUsableRelease:
            // 초안/프리릴리스만 있는 저장소 — 사용자에게는 "최신"과 구분되지 않는다.
            log.info("update check: no usable release (draft/prerelease only)")
            if manual { presentation = .upToDate(current: currentVersion) }
        }
    }

    private func present(release: UpdateRelease, manual: Bool) {
        guard release.version > currentVersion else {
            if manual { presentation = .upToDate(current: currentVersion) }
            return
        }
        // Skip Version은 **자동 확인만** 침묵시킨다(D4). 수동 확인은 언제나 결과를 보여준다.
        if !manual, preferences.isSkipped(release.version) {
            log.info("update check: version \(release.version.description, privacy: .public) is skipped")
            return
        }
        presentation = .available(release, current: currentVersion)
    }

    private func handle(_ error: UpdateCheckError, manual: Bool) {
        guard manual else {
            // **자동 확인 실패는 완전 침묵**(D4) — 로그만 남긴다.
            log.info("automatic update check failed silently: \(String(describing: error), privacy: .public)")
            return
        }
        presentation = .failed(message: error.message)
    }

    // MARK: - 사용자 액션

    /// [Download] — 릴리스 **페이지**를 브라우저로 연다. 앱은 파일을 내려받지 않는다(설계서 §1.2 (b)).
    @discardableResult
    func download(_ release: UpdateRelease) -> Bool {
        presentation = nil
        return opener(release.pageURL)
    }

    /// [Skip This Version] — 그 버전은 자동 확인에서만 침묵한다.
    func skip(_ release: UpdateRelease) {
        preferences.skip(release.version)
        presentation = nil
    }

    /// [Later] / [OK] — 아무것도 저장하지 않는다.
    func dismiss() {
        presentation = nil
    }
}
