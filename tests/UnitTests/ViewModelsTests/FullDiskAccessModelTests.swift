import AppKit
import XCTest
@testable import UniFinder

/// `FullDiskAccessModel` (m3-impl T5 / UI설계 §7.5) 단위 테스트.
///
/// 실제 TCC 권한·시스템 설정 앱에 의존하지 않도록 프로브와 URL opener를 주입하고,
/// `UserDefaults`는 테스트마다 전용 suite를 쓴다(전역 설정 오염 금지).
@MainActor
final class FullDiskAccessModelTests: XCTestCase {

    /// 감지 결과를 도중에 바꿀 수 있는 프로브 — "미허용 → 설정에서 허용 → 복귀" 왕복 재현용.
    private final class SwitchableProbe: ProtectedPathProbing, @unchecked Sendable {

        let candidates: [ProtectedPath] = [.directory("/probe/switchable")]

        private let lock = NSLock()
        private var outcome: ProbeOutcome

        init(_ outcome: ProbeOutcome) {
            self.outcome = outcome
        }

        func set(_ newOutcome: ProbeOutcome) {
            lock.lock()
            outcome = newOutcome
            lock.unlock()
        }

        func probe(_ candidate: ProtectedPath) -> ProbeOutcome {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "UniFinderTests-FDA-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "테스트 전용 UserDefaults suite 생성 실패")
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeModel(
        _ outcome: ProbeOutcome,
        opener: @escaping @MainActor (URL) -> Bool = { _ in true }
    ) -> (model: FullDiskAccessModel, probe: SwitchableProbe) {
        let probe = SwitchableProbe(outcome)
        let model = FullDiskAccessModel(probe: probe, defaults: defaults, opener: opener)
        return (model, probe)
    }

    // MARK: - 다중 창 배너 게이팅 (reviewer Major 2)

    /// **핵심 회귀** — 시트는 소유 창 하나에만 뜨는데, 배너까지 전 창에서 숨기면
    /// **시트를 보지도 못한 창들이 제한 모드라는 사실 자체를 알 수 없다.**
    ///
    /// `isOnboardingPresented`는 앱 전역 공유 인스턴스의 `Bool` 하나라서, 예전 구현
    /// (`guard !isOnboardingPresented`)은 소유 창에 시트가 뜨는 순간 **모든 창의 배너**를 껐다.
    func testShouldShowBanner_whileSheetIsOpen_staysVisibleOnNonPresenterWindows() {
        let (model, _) = makeModel(.denied)

        model.start()
        XCTAssertTrue(model.isOnboardingPresented, "전제 확인 — 미허용이면 시트가 뜬다")

        XCTAssertFalse(
            model.shouldShowBanner(isPresenter: true),
            "시트에 실제로 가려지는 소유 창에서는 배너를 중복 노출하지 않는다"
        )
        XCTAssertTrue(
            model.shouldShowBanner(isPresenter: false),
            "시트를 띄우지 않는 창은 배너로만 제한 모드를 알 수 있다 — 여기서 숨기면 안내가 통째로 사라진다"
        )
    }

    /// 판정 불가(`.undetermined`)에서도 같은 규칙이다 — 시트는 아예 안 뜨므로 전 창이 배너를 본다.
    func testShouldShowBanner_undetermined_showsOnEveryWindow() {
        let (model, _) = makeModel(.missing)
        model.start()

        XCTAssertFalse(model.isOnboardingPresented, "전제 확인 — 판정 불가는 시트를 띄우지 않는다(B22)")
        XCTAssertTrue(model.shouldShowBanner(isPresenter: true))
        XCTAssertTrue(model.shouldShowBanner(isPresenter: false))
    }

    /// 허용된 상태에서는 소유 여부와 무관하게 아무 창에도 배너가 없다.
    func testShouldShowBanner_granted_isHiddenOnEveryWindow() {
        let (model, _) = makeModel(.readable)
        model.start()

        XCTAssertFalse(model.shouldShowBanner(isPresenter: true))
        XCTAssertFalse(model.shouldShowBanner(isPresenter: false))
    }

    /// 편의 프로퍼티는 소유 창 기준(= 단일 창 시절 의미론)을 유지한다.
    func testShouldShowBannerProperty_matchesPresenterSemantics() {
        let (model, _) = makeModel(.denied)
        model.start()

        XCTAssertEqual(model.shouldShowBanner, model.shouldShowBanner(isPresenter: true))
    }

    // MARK: - 첫 실행 안내

    func testStart_whenDenied_presentsOnboarding() {
        let (model, _) = makeModel(.denied)

        model.start()

        XCTAssertEqual(model.status, .denied)
        XCTAssertTrue(model.isOnboardingPresented, "미허용 감지 시 웰컴 시트를 띄워야 한다(UI설계 §7.5)")
        XCTAssertFalse(model.shouldShowBanner, "시트가 떠 있는 동안 배너는 중복 노출하지 않는다")
    }

    func testStart_whenGranted_showsNothing() {
        let (model, _) = makeModel(.readable)

        model.start()

        XCTAssertEqual(model.status, .granted)
        XCTAssertFalse(model.isOnboardingPresented)
        XCTAssertFalse(model.shouldShowBanner)
    }

    /// B22 — 판정 불가는 미허용으로 단정하지 않는다: 시트 금지, 온화한 배너만.
    func testStart_whenUndetermined_doesNotPresentSheet_showsGentleBannerOnly() {
        let (model, _) = makeModel(.missing)

        model.start()

        XCTAssertEqual(model.status, .undetermined)
        XCTAssertFalse(model.isOnboardingPresented, "판정 불가에서 시트를 띄우면 오탐 안내가 된다(B22)")
        XCTAssertTrue(model.shouldShowBanner)
        XCTAssertEqual(model.bannerMessage, "Some folders may require Full Disk Access.")
    }

    func testStart_isIdempotent() {
        let (model, _) = makeModel(.denied)

        model.start()
        model.postpone()
        model.start()

        XCTAssertFalse(model.isOnboardingPresented, "start()는 1회만 동작해야 한다")
    }

    // MARK: - [나중에] 제한 모드

    func testPostpone_closesSheetAndKeepsBanner() {
        let (model, _) = makeModel(.denied)
        model.start()

        model.postpone()

        XCTAssertFalse(model.isOnboardingPresented)
        XCTAssertTrue(model.isPostponed)
        XCTAssertTrue(model.shouldShowBanner, "제한 모드임을 계속 알려야 한다")
        XCTAssertEqual(model.bannerMessage, "Limited mode — some folders can't be opened without Full Disk Access.")
    }

    func testDismissingSheetDirectly_marksPostponed() {
        let (model, _) = makeModel(.denied)
        model.start()

        // Esc / 바깥 클릭으로 시트가 닫히는 경로(뷰 바인딩이 직접 false로 만든다)
        model.isOnboardingPresented = false

        XCTAssertTrue(model.isPostponed, "닫힘을 보류로 간주하지 않으면 다음 활성화에서 시트가 다시 튀어나온다")
    }

    func testStart_afterPostponedInPreviousLaunch_doesNotAutoPresent() {
        let first = makeModel(.denied)
        first.model.start()
        first.model.postpone()

        // 같은 defaults를 공유하는 새 인스턴스 = 다음 실행
        let second = makeModel(.denied)
        second.model.start()

        XCTAssertFalse(second.model.isOnboardingPresented, "[나중에] 이후 매 실행마다 시트를 띄우면 안 된다")
        XCTAssertTrue(second.model.shouldShowBanner)
    }

    /// 접근 불가 폴더 empty-state의 [권한 설정 안내] 버튼 경로 — 보류 상태여도 명시 요청이면 연다.
    func testPresent_whenPostponed_stillPresents() {
        let (model, _) = makeModel(.denied)
        model.start()
        model.postpone()

        model.present()

        XCTAssertTrue(model.isOnboardingPresented)
    }

    // MARK: - 재감지 (didBecomeActive)

    func testRefresh_afterPermissionGranted_closesSheetAutomatically() {
        let (model, probe) = makeModel(.denied)
        model.start()
        XCTAssertTrue(model.isOnboardingPresented)

        // 사용자가 시스템 설정에서 허용하고 앱으로 복귀
        probe.set(.readable)
        model.refresh()

        XCTAssertEqual(model.status, .granted)
        XCTAssertFalse(model.isOnboardingPresented, "허용되면 시트가 자동으로 닫혀야 한다(UI설계 §7.5-3)")
        XCTAssertFalse(model.shouldShowBanner)
        XCTAssertFalse(model.isPostponed, "허용되면 보류 플래그도 해제한다")
    }

    func testRefresh_withoutPresentIfNeeded_doesNotPopSheetOnEveryActivation() {
        let (model, _) = makeModel(.denied)
        model.start()
        model.postpone()

        model.refresh()

        XCTAssertEqual(model.status, .denied)
        XCTAssertFalse(model.isOnboardingPresented, "활성화 재감지가 시트를 다시 띄우면 안 된다")
    }

    func testRefresh_permissionRevoked_returnsToDeniedBanner() {
        let (model, probe) = makeModel(.readable)
        model.start()

        probe.set(.denied)
        let status = model.refresh()

        XCTAssertEqual(status, .denied)
        XCTAssertTrue(model.shouldShowBanner)
    }

    /// 조건이 만족될 때까지 메인 액터를 양보하며 기다린다.
    ///
    /// 활성화 재감지는 (1) 메인 큐의 옵저버 블록 → (2) 메인 액터 밖 프로브 → (3) 메인 액터 반영의
    /// 3단이라 런루프 1회로는 부족하다(M3 리뷰 권장 1 — 프로브를 `Task.detached`로 뺐다).
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testActivationNotification_triggersRefresh() async {
        let (model, probe) = makeModel(.denied)
        model.start()
        model.postpone()

        probe.set(.readable)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { model.status == .granted }

        XCTAssertEqual(model.status, .granted, "didBecomeActive 시점에 재감지해야 한다(ClipboardModel과 동일 패턴)")
    }

    func testStopObservingActivation_stopsRefreshing() async {
        let (model, probe) = makeModel(.denied)
        model.start()
        model.postpone()
        model.stopObservingActivation()

        probe.set(.readable)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil(timeout: 0.5) { model.status == .granted }

        XCTAssertEqual(model.status, .denied)
    }

    /// **M3 리뷰 blocker 2 회귀** — 창을 닫았다가(=`stop`) 다시 열면(=`start`) 재감지가 살아나야 한다.
    ///
    /// 예전에는 `start()`가 별도 `didStart` 플래그로 가드했는데 `stopObservingActivation()`이
    /// 그 플래그를 내리지 않았다. 그래서 Dock에서 창을 다시 여는 순간부터 `didBecomeActive` 재감지가
    /// **영구히** 죽고 최초 probe도 돌지 않아, T5 수용 기준("설정에서 허용 → 앱 복귀 시 자동 감지·
    /// 시트 닫힘")이 그 시점부터 성립하지 않았다.
    func testRestartAfterStop_resumesActivationDetection() async {
        let (model, probe) = makeModel(.denied)
        model.start()
        model.postpone()

        // 창 닫힘
        model.stopObservingActivation()
        // Dock 아이콘 클릭 → 창 재생성 → AppModel.start() → fullDiskAccess.start()
        model.start()

        probe.set(.readable)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { model.status == .granted }

        XCTAssertEqual(
            model.status, .granted,
            "stop() 후 start()가 관측자를 다시 등록하지 않으면 재감지가 영구히 죽는다(blocker 2)"
        )
    }

    /// 재시작 시 **최초 probe도 다시 돈다** — 그 사이 권한이 바뀌었을 수 있다.
    func testRestartAfterStop_reRunsInitialProbe() {
        let (model, probe) = makeModel(.denied)
        model.start()
        model.postpone()
        model.stopObservingActivation()

        probe.set(.readable)
        model.start()

        XCTAssertEqual(model.status, .granted, "재시작 시 최초 감지가 생략되면 낡은 상태가 그대로 남는다(blocker 2)")
    }

    /// 재시작이 관측자를 **중복 등록**하지는 않아야 한다(가드가 사라지면 알림 1건에 재감지가 여러 번 돈다).
    func testStart_whileAlreadyObserving_doesNotRegisterTwice() {
        let (model, probe) = makeModel(.denied)
        model.start()
        model.postpone()

        probe.set(.readable)
        model.start()

        XCTAssertEqual(model.status, .denied, "이미 감시 중이면 start()는 아무것도 하지 않아야 한다")
    }

    // MARK: - 프로브 실행 위치 (M3 리뷰 권장 1)

    /// 활성화 재감지는 메인 액터에서 동기 파일 IO를 하지 않는다.
    /// 프로브가 블로킹해도 메인 액터가 계속 돌아야 한다 — 그러지 않으면 앱 활성화가 눈에 띄게 끊긴다.
    func testActivationRefresh_doesNotBlockMainActor() async {
        let probe = BlockingProbe()
        let model = FullDiskAccessModel(probe: probe, defaults: defaults, opener: { _ in true })

        let task = model.refreshInBackground()

        // 프로브가 메인 액터에서 돌면 이 폴링 자체가 진행되지 못해 교착 → 타임아웃으로 드러난다.
        await waitUntil { probe.didEnterProbe }
        XCTAssertTrue(
            probe.didEnterProbe,
            "프로브가 메인 액터를 붙들면 앱 활성화가 그동안 멈춘다(권장 1 — Task.detached로 분리)"
        )

        probe.release()
        _ = await task.value
        XCTAssertEqual(model.status, .granted, "백그라운드 프로브 결과는 메인 액터 상태에 반영되어야 한다")
    }

    /// 메인 액터 밖에서 실행되는지 확인하기 위해, 신호를 줄 때까지 스레드를 붙잡는 프로브.
    private final class BlockingProbe: ProtectedPathProbing, @unchecked Sendable {

        let candidates: [ProtectedPath] = [.directory("/probe/blocking")]

        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var enteredProbe = false

        var didEnterProbe: Bool {
            lock.lock()
            defer { lock.unlock() }
            return enteredProbe
        }

        func release() {
            gate.signal()
        }

        func probe(_ candidate: ProtectedPath) -> ProbeOutcome {
            lock.lock()
            enteredProbe = true
            lock.unlock()
            gate.wait()
            return .readable
        }
    }

    // MARK: - 설정 딥링크

    func testOpenSystemSettings_usesFullDiskAccessDeepLink() {
        var opened: [URL] = []
        let (model, _) = makeModel(.denied, opener: { url in
            opened.append(url)
            return true
        })

        XCTAssertTrue(model.openSystemSettings())
        XCTAssertEqual(
            opened.map(\.absoluteString),
            ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"],
            "UI설계 §7.5가 지정한 딥링크를 먼저 시도해야 한다"
        )
        XCTAssertFalse(model.deepLinkFailed)
    }

    func testOpenSystemSettings_fallsBackToSecondaryPaneID() {
        var opened: [URL] = []
        let (model, _) = makeModel(.denied, opener: { url in
            opened.append(url)
            // 첫 번째 URL은 열리지 않는 상황(구 pane id 미지원)을 가정
            return opened.count > 1
        })

        XCTAssertTrue(model.openSystemSettings())
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(opened[1].absoluteString.contains("Privacy_AllFiles"))
    }

    func testOpenSystemSettings_allFail_marksDeepLinkFailed() {
        let (model, _) = makeModel(.denied, opener: { _ in false })

        XCTAssertFalse(model.openSystemSettings())
        XCTAssertTrue(model.deepLinkFailed, "딥링크 실패 시 수동 경로 안내를 노출해야 한다")
    }

    func testDeepLinks_areAllPrivacyAllFilesAnchors() {
        XCTAssertFalse(FullDiskAccessModel.settingsDeepLinks.isEmpty)
        for url in FullDiskAccessModel.settingsDeepLinks {
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
            XCTAssertTrue(url.absoluteString.hasSuffix("Privacy_AllFiles"))
        }
    }

    // MARK: - 다중 창 소유권 (다중 창 지원 — 여러 창이 같은 FullDiskAccessModel을 공유할 때)

    /// 창 A·창 B가 같은 `FullDiskAccessModel`을 공유하며 각자 다른 `owner`로 `start(owner:)`를
    /// 부른 상황을 흉내낸다. 창 하나만 닫혀도(그 창의 owner만 해제) 다른 창이 아직 열려
    /// 있으므로 재감지는 계속 살아 있어야 한다.
    func testStartTwoOwners_thenStopObservingOne_stillReactsToActivation() async {
        let (model, probe) = makeModel(.denied)
        let windowA = UUID()
        let windowB = UUID()
        model.start(owner: windowA)
        model.postpone()
        model.start(owner: windowB)

        model.stopObservingActivation(owner: windowA)

        probe.set(.readable)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { model.status == .granted }

        XCTAssertEqual(
            model.status, .granted,
            "두 창이 관측 중인데 한 창만 닫혔다고 재감지가 죽으면 안 된다(다른 창의 FDA 재감지가 죽는다)"
        )
    }

    /// 두 창이 각자 시작했으면 두 창이 각자 해제해야 완전히 멈춘다.
    func testStartTwoOwners_thenStopObservingBoth_noLongerReactsToActivation() async {
        let (model, probe) = makeModel(.denied)
        let windowA = UUID()
        let windowB = UUID()
        model.start(owner: windowA)
        model.postpone()
        model.start(owner: windowB)

        model.stopObservingActivation(owner: windowA)
        model.stopObservingActivation(owner: windowB)

        probe.set(.readable)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil(timeout: 0.5) { model.status == .granted }

        XCTAssertEqual(
            model.status, .denied,
            "시작한 횟수만큼 해제됐다면 재감지가 완전히 멈춰야 한다"
        )
    }
}
