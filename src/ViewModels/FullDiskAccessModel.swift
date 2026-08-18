import AppKit
import Foundation
import Observation

/// FDA 온보딩 상태 (m3-impl T5 / UI설계 §7.5).
///
/// 흐름: 첫 실행·미허용 감지 → 웰컴 시트 → [시스템 설정 열기] 딥링크 → 앱 활성화 때마다 재감지
/// → 허용되면 시트 자동 닫힘. [나중에]를 고르면 제한 모드로 계속 쓰고, 보호 폴더 진입 시
/// empty-state의 [권한 설정 안내]로 다시 열 수 있다.
///
/// **재감지 시점**: `ClipboardModel.startObservingPasteboard`와 동일한
/// `NSApplication.didBecomeActiveNotification` 패턴을 쓴다(architect B6와 일관 — 상시 폴링 금지).
///
/// **B22**: 판정은 3상태다. `.undetermined`(후보 경로가 전부 없음 등)에서는 시트를 띄우지 않고
/// 온화한 배너만 보여준다 — 미허용으로 단정하지 않는다.
///
/// **B21**: 개발 빌드는 ad-hoc 서명이라 빌드할 때마다 TCC 승인이 초기화된다. "허용했는데 다시
/// 미허용으로 감지된다"는 개발 중 현상은 이 구현의 버그가 아니라 서명 전제조건 때문이며,
/// Developer ID 서명 전환은 릴리스 직전 별도 작업이다(m3-impl B21 방침 (b)).
@Observable
@MainActor
final class FullDiskAccessModel {

    private enum Key {
        /// [나중에]를 눌러 자동 안내를 보류했는지. 이 값이 없으면 = 아직 안내한 적 없음(첫 실행).
        static let postponed = "fullDiskAccessOnboardingPostponed"
    }

    /// 마지막 감지 결과.
    private(set) var status: FullDiskAccessStatus = .undetermined

    /// 웰컴 시트 표시 여부. 뷰가 `Bindable`로 양방향 연결하므로 `var`다.
    var isOnboardingPresented = false {
        didSet {
            // 시트가 닫히면(사용자가 Esc/바깥 클릭으로 닫는 경우 포함) 보류로 간주해 재노출 폭주를 막는다.
            if oldValue, !isOnboardingPresented, status != .granted {
                markPostponed()
            }
        }
    }

    /// 딥링크를 열지 못했을 때 시트에 띄우는 안내(수동 경로 안내).
    private(set) var deepLinkFailed = false

    @ObservationIgnored
    private let probe: any ProtectedPathProbing

    @ObservationIgnored
    private let defaults: UserDefaults

    /// `NSWorkspace.open` 주입점 — 테스트가 실제 시스템 설정을 열지 않게 한다.
    @ObservationIgnored
    private let opener: @MainActor (URL) -> Bool

    @ObservationIgnored
    private var activationObserver: NSObjectProtocol?

    /// 감시를 요청한 **창들**의 식별자 (다중 창 T1 — `ClipboardModel`과 같은 규약).
    ///
    /// 이 모델은 `AppEnvironment`가 소유하는 앱 전역 인스턴스라 창 N개가 같은 인스턴스에
    /// `start`/`stopObservingActivation`을 건다. 참조 카운트(`Int`) 대신 **집합**을 쓰는 이유는
    /// SwiftUI가 뷰 아이덴티티 변화 시 `onAppear`/`onDisappear`를 추가로 호출할 수 있어
    /// 카운트가 드리프트(음수/누수)하기 때문이다 — 집합은 중복 호출에 멱등이다.
    @ObservationIgnored
    private var observingOwners: Set<UUID> = []

    /// 소유자를 지정하지 않은 호출(단일 소유자·테스트)이 공유하는 고정 토큰.
    static let defaultOwnerID = UUID()

    /// 진행 중인 활성화 재감지 작업 (테스트가 완료를 기다리는 지점).
    /// 프로브는 파일 IO라서 메인 액터 밖에서 돌린다 — 아래 `refreshInBackground` 참조.
    @ObservationIgnored
    private(set) var activationRefreshTask: Task<FullDiskAccessStatus, Never>?

    init(
        probe: any ProtectedPathProbing = FullDiskAccessProbe(),
        defaults: UserDefaults = .standard,
        opener: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.probe = probe
        self.defaults = defaults
        self.opener = opener
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    // MARK: - 파생 상태

    /// 제한 모드 안내 배너를 띄울지 (UI설계 §7.5 / 설계 §8 — 판정 불가는 "온화하게").
    ///
    /// - `.denied`: 시트를 닫은 뒤에도 제한 모드임을 계속 알린다
    /// - `.undetermined`: 시트는 절대 띄우지 않고 배너만
    /// - `.granted`: 아무것도 띄우지 않는다
    ///
    /// **다중 창 (reviewer Major 2)**: 이 판정은 **창별**이다. `isOnboardingPresented`는 앱 전역
    /// 공유 인스턴스의 `Bool` 하나인데, 시트는 소유 창 하나에만 뜬다(`AppEnvironment.onboardingPresenterID`).
    /// 그래서 "시트가 떠 있으니 배너를 숨긴다"는 규칙을 전 창에 적용하면 **시트를 보지도 못한 창들이
    /// 배너까지 잃어** 제한 모드라는 사실 자체를 알 수 없게 된다. 숨기는 것은 **실제로 시트에 가려지는
    /// 소유 창뿐**이다.
    ///
    /// - Parameter isPresenter: 이 창이 시트 소유 창인지.
    func shouldShowBanner(isPresenter: Bool) -> Bool {
        // 시트에 가려지는 창에서만 중복 노출을 피한다.
        if isPresenter, isOnboardingPresented { return false }
        switch status {
        case .granted: return false
        case .denied, .undetermined: return true
        }
    }

    /// 소유 창 기준(= 단일 창 시절과 같은) 판정. 창이 하나뿐인 문맥과 단위 테스트가 쓴다.
    var shouldShowBanner: Bool { shouldShowBanner(isPresenter: true) }

    var bannerMessage: String {
        switch status {
        case .denied:
            return "Limited mode — some folders can't be opened without Full Disk Access."
        case .undetermined:
            return "Some folders may require Full Disk Access."
        case .granted:
            return ""
        }
    }

    /// [나중에]를 눌러 자동 안내를 보류한 상태인지.
    var isPostponed: Bool { defaults.bool(forKey: Key.postponed) }

    // MARK: - 수명주기

    /// 창이 열릴 때 — 최초 감지 + 활성화 감시 시작 + 필요 시 웰컴 시트.
    ///
    /// **가드 기준은 `didStart` 같은 별도 플래그가 아니라 관측자 등록 여부다** (M3 리뷰 blocker 2).
    /// 형제 모델들과 같은 규칙이다: `ClipboardModel`은 `guard activationObserver == nil`,
    /// `TreeModel`은 `guard volumeObservers.isEmpty`. 별도 플래그를 쓰면 `stop()`이 그 플래그를
    /// 내리지 않는 순간 재시작이 **영구히** 죽는다 — 창을 닫았다가 Dock에서 다시 열면
    /// `didBecomeActive` 재감지가 살아나지 않아 T5 수용 기준("설정에서 허용 → 복귀 시 자동 감지·
    /// 시트 닫힘")이 그 시점부터 성립하지 않았다.
    ///
    /// **다중 창 T1**: 창 N개가 같은 인스턴스에 걸므로 **빈 집합 → 첫 소유자** 전이에서만
    /// 관측자 등록과 최초 프로브(`refresh(presentIfNeeded: true)`)를 수행한다. 두 번째 창이
    /// 열릴 때 최초 프로브를 다시 돌리면 [나중에]로 보류하지 않은 사용자에게 시트가 또 뜬다.
    /// 아래 `guard activationObserver == nil`은 기존 방어선을 그대로 남긴 것이다.
    /// - Parameter owner: 창 식별자. 생략하면 `defaultOwnerID`(단일 소유자 의미론).
    func start(owner: UUID = FullDiskAccessModel.defaultOwnerID) {
        let wasEmpty = observingOwners.isEmpty
        observingOwners.insert(owner)
        guard wasEmpty else { return }
        guard activationObserver == nil else { return }
        startObservingActivation()
        refresh(presentIfNeeded: true)
    }

    /// 앱 재활성화 시점마다 권한을 재감지한다 (ClipboardModel과 동일 패턴).
    ///
    /// **`start()`만 부를 수 있다**(M3 리뷰 선택 4). 외부에서 이걸 먼저 부르면 관측자가 등록되면서
    /// `start()`의 `guard activationObserver == nil`에 걸려 **최초 프로브와 웰컴 시트가 조용히 스킵**된다 —
    /// 증상이 "첫 실행에서 아무 안내도 안 뜬다"로만 나타나 원인을 찾기 어렵다.
    private func startObservingActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 활성화 경로는 메인 액터에서 동기 파일 IO를 하지 않는다(M3 리뷰 권장 1).
                _ = self?.refreshInBackground()
            }
        }
    }

    /// - Parameter owner: 창 식별자. **마지막 소유자가 빠질 때만** 실제로 해제한다 —
    ///   창 하나를 닫았다고 살아 있는 창의 FDA 재감지까지 끊으면 안 된다(다중 창 T1).
    func stopObservingActivation(owner: UUID = FullDiskAccessModel.defaultOwnerID) {
        observingOwners.remove(owner)
        guard observingOwners.isEmpty else { return }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        activationRefreshTask?.cancel()
        activationRefreshTask = nil
    }

    // MARK: - 감지

    /// 권한을 재감지한다 (동기 — 창이 열리는 1회성 경로와 테스트가 쓴다).
    /// - Parameter presentIfNeeded: 첫 실행/미허용일 때 웰컴 시트를 띄울지 (앱 시작 시에만 `true`)
    /// - Returns: 갱신된 상태
    @discardableResult
    func refresh(presentIfNeeded: Bool = false) -> FullDiskAccessStatus {
        apply(probe.evaluateStatus(), presentIfNeeded: presentIfNeeded)
    }

    /// 활성화 재감지 — **프로브의 파일 IO를 메인 액터 밖에서** 수행하고 결과만 반영한다(M3 리뷰 권장 1).
    ///
    /// 프로브는 후보 4개를 순차로 `contentsOfDirectory`/`FileHandle`로 읽는다. 보통 ms 단위지만
    /// 디스크가 바쁜 순간에는 앱 활성화가 눈에 띄게 끊긴다 — `didBecomeActive`마다 도는 경로라
    /// 메인 액터에서 동기로 돌릴 이유가 없다.
    @discardableResult
    func refreshInBackground(presentIfNeeded: Bool = false) -> Task<FullDiskAccessStatus, Never> {
        activationRefreshTask?.cancel()
        let probe = self.probe
        let task = Task { @MainActor [weak self] in
            let newStatus = await Task.detached(priority: .utility) { probe.evaluateStatus() }.value
            // 감시가 해제된 뒤 도착한 결과는 버린다(`stopObservingActivation` 이후 반영 금지).
            guard let self, !Task.isCancelled else { return newStatus }
            return self.apply(newStatus, presentIfNeeded: presentIfNeeded)
        }
        activationRefreshTask = task
        return task
    }

    /// 감지 결과를 상태·시트에 반영하는 단일 지점 (동기 경로와 백그라운드 경로가 공유한다).
    @discardableResult
    private func apply(_ newStatus: FullDiskAccessStatus, presentIfNeeded: Bool) -> FullDiskAccessStatus {
        status = newStatus

        if newStatus == .granted {
            // 허용되면 시트를 자동으로 닫는다 (UI설계 §7.5-3).
            // `didSet`의 보류 처리를 타지 않도록 상태를 먼저 반영한 뒤 닫는다.
            isOnboardingPresented = false
            defaults.set(false, forKey: Key.postponed)
            return newStatus
        }

        // 판정 불가(.undetermined)는 시트를 띄우지 않는다 — 미허용으로 단정 금지(B22).
        guard presentIfNeeded, newStatus == .denied, !isPostponed else { return newStatus }
        present()
        return newStatus
    }

    // MARK: - 사용자 액션

    /// 웰컴 시트를 연다. empty-state의 [권한 설정 안내] 버튼도 이 경로를 쓴다
    /// (보류 상태여도 사용자가 명시적으로 요청했으므로 무조건 연다).
    func present() {
        deepLinkFailed = false
        isOnboardingPresented = true
    }

    /// [나중에] — 제한 모드로 계속 사용한다.
    func postpone() {
        markPostponed()
        isOnboardingPresented = false
    }

    /// [시스템 설정 열기] — 개인정보 보호 및 보안 > 전체 디스크 접근으로 딥링크한다.
    /// - Returns: 딥링크를 연 경우 `true`
    @discardableResult
    func openSystemSettings() -> Bool {
        for url in Self.settingsDeepLinks {
            guard opener(url) else { continue }
            deepLinkFailed = false
            return true
        }
        deepLinkFailed = true
        return false
    }

    /// 설정 딥링크 후보 (macOS 14+).
    ///
    /// 첫 번째가 UI설계 §7.5가 지정한 URL이고 Ventura 이후에도 새 설정 앱의 해당 창으로 매핑된다.
    /// 두 번째는 새 설정 앱의 extension 번들 id를 직접 지정하는 형태로, 첫 번째가 실패할 때의 대안이다.
    static let settingsDeepLinks: [URL] = [
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"),
    ].compactMap { $0 }

    private func markPostponed() {
        defaults.set(true, forKey: Key.postponed)
    }
}
