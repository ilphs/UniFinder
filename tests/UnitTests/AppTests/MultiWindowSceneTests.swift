import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// **다중 창 규약 회귀** (multiwindow-impl T5). ralph 작성.
///
/// 이 파일은 옛 `SingleWindowSceneTests`를 대체한다. 그 파일은 "창은 하나뿐"을 씬 타입으로
/// 못 박았는데, 그건 결함 자체가 아니라 **결함의 원인**(앱 레벨 `@State`로 만든 `AppModel` 하나를
/// 모든 창이 공유한다)을 봉인한 것이었다. 원인을 없앴으므로 봉인도 걷고, 대신 그 결함이
/// 되살아나지 못하게 하는 **새 불변식 4개**를 여기서 지킨다:
///
/// (a) 메인 씬은 `WindowGroup`이다 — ⌘N/컨텍스트 메뉴로 창을 여러 개 열 수 있다
/// (b) 창마다 `AppModel`이 **다른 인스턴스**다 — 탐색·트리·히스토리가 창 안에 갇힌다
/// (c) 설정·클립보드·FDA는 창을 넘어 **같은 인스턴스**다 — 창 A에서 ⌘C, 창 B에서 ⌘V가 된다
/// (d) 한 창의 `stop()`이 **다른 창의 감시자를 끊지 않는다** — 옛 봉인이 막으려던 바로 그 결함
@MainActor
final class MultiWindowSceneTests: XCTestCase {

    // MARK: - 격리 헬퍼

    /// `AppEnvironment.shared`를 절대 건드리지 않는 테스트 전용 환경.
    /// (`UserDefaults.standard`/`NSPasteboard.general`을 쓰면 테스트끼리 오염된다)
    private func makeEnvironment() -> AppEnvironment {
        makeEnvironment(pasteboard: NSPasteboard(name: NSPasteboard.Name("UniFinderTest-MultiWindow-\(UUID().uuidString)")))
    }

    private func makeEnvironment(pasteboard: NSPasteboard) -> AppEnvironment {
        let suiteName = "UniFinderTests-MultiWindow-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("테스트 전용 UserDefaults suite 생성 실패")
            return AppEnvironment()
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return AppEnvironment(
            settings: AppSettings(defaults: defaults),
            clipboard: ClipboardModel(pasteboard: pasteboard),
            fullDiskAccess: FullDiskAccessModel(
                probe: MockProtectedPathProbe([.readable]),
                defaults: defaults,
                opener: { _ in true }
            )
        )
    }

    // MARK: - (a) 씬 타입

    /// 씬 타입 이름으로 확인한다 — 테스트는 앱을 띄우지 않으므로 런타임에 창을 세어 볼 수단이 없다.
    func testMainScene_isWindowGroup() {
        let sceneType = String(describing: type(of: UniFinderApp().body))

        XCTAssertTrue(
            sceneType.contains("WindowGroup"),
            "메인 씬이 WindowGroup이 아니면 ⌘N/컨텍스트 메뉴가 창을 열 수 없다: \(sceneType)"
        )
    }

    /// 시드에 `UUID`가 없으면 `WindowGroup(for:)`이 **같은 값 = 같은 창**으로 취급해
    /// ⌘N을 연타해도 기존 창만 앞으로 나온다(새 창이 생기지 않는다).
    func testWindowSeed_sameFolderProducesDistinctValues() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
        let first = WindowSeed(folderURL: folder)
        let second = WindowSeed(folderURL: folder)

        XCTAssertNotEqual(
            first, second,
            "같은 폴더 시드가 동일 값이면 WindowGroup이 새 창을 만들지 않고 기존 창만 앞으로 가져온다"
        )
        XCTAssertEqual(first.folderURL?.path, second.folderURL?.path)
    }

    /// 런치 창은 시드가 없다 — 홈으로 폴백해야 한다(폴백이 없으면 창이 뜨지 않거나 빈 창이 뜬다).
    func testLaunchSeed_fallsBackToHome() {
        XCTAssertEqual(
            WindowSeed.launchDefault().folderURL?.path,
            FileManager.default.homeDirectoryForCurrentUser.path
        )

        let environment = makeEnvironment()
        let model = MainWindowRoot.makeWindowModel(seed: nil, environment: environment)
        XCTAssertEqual(
            model.navigation.currentURL.path,
            NavigationModel.normalize(FileManager.default.homeDirectoryForCurrentUser).path,
            "시드가 nil인 런치 창이 홈으로 폴백하지 않으면 첫 창이 뜨지 않는다"
        )
    }

    /// **회귀 (reviewer m1)** — 창 복원은 종료 시점의 시드를 되살리는데, 그 사이 폴더가 지워졌을 수 있다.
    ///
    /// `AppModel.init`은 `normalize`만 하고 존재 가드는 `navigate()`에만 있어서, 시드를 그대로
    /// 넘기면 **`error` 상태로 멈춘 창**이 뜬다 — 앱의 다른 모든 경로가 지키는 "가장 가까운 상위
    /// 폴더로 이동"(설계서 §6)에서 이 경로만 빠지게 된다.
    func testSeedPointingAtDeletedFolder_fallsBackToNearestExistingParent() throws {
        let environment = makeEnvironment()
        let root = try makeTempDirectory()
        let vanished = root.appendingPathComponent("gone", isDirectory: true)
        // 시드는 만들어졌을 당시엔 존재했지만 복원 시점에는 없는 폴더를 흉내낸다(생성하지 않는다).

        let model = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: vanished), environment: environment)

        XCTAssertEqual(
            model.navigation.currentURL.path,
            NavigationModel.normalize(root).path,
            "사라진 폴더 시드를 그대로 열면 error 상태로 멈춘 창이 뜬다 — 상위로 폴백해야 한다(설계서 §6)"
        )
    }

    /// 존재하는 폴더 시드는 폴백 가드를 거쳐도 그대로여야 한다(가드가 과하게 걷어내지 않는지).
    func testSeedPointingAtExistingFolder_isUnchangedByFallbackGuard() throws {
        let environment = makeEnvironment()
        let root = try makeTempDirectory()

        let model = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)

        XCTAssertEqual(model.navigation.currentURL.path, NavigationModel.normalize(root).path)
    }

    // MARK: - (b) 창마다 다른 AppModel

    func testEachWindow_getsItsOwnAppModel() {
        let environment = makeEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser

        let first = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: home), environment: environment)
        let second = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: home), environment: environment)

        XCTAssertFalse(first === second, "창마다 AppModel이 하나씩 생겨야 탐색이 창 안에 갇힌다")
        XCTAssertNotEqual(first.windowID, second.windowID)
        XCTAssertFalse(first.navigation === second.navigation, "히스토리가 공유되면 한 창의 뒤로가기가 다른 창을 움직인다")
        XCTAssertFalse(first.directory === second.directory)
        XCTAssertFalse(first.tree === second.tree)
    }

    /// 시드의 폴더가 그 창의 시작 위치가 된다(⌘N = 현재 창의 폴더 — 사용자 결정).
    func testSeedFolder_becomesStartURLOfThatWindowOnly() throws {
        let environment = makeEnvironment()
        let root = try makeTempDirectory()
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let first = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)
        let second = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: child), environment: environment)

        XCTAssertEqual(first.navigation.currentURL.path, NavigationModel.normalize(root).path)
        XCTAssertEqual(second.navigation.currentURL.path, NavigationModel.normalize(child).path)
    }

    // MARK: - (c) 공유 인스턴스

    func testSharedState_isTheSameInstanceAcrossWindows() {
        let environment = makeEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser

        let first = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: home), environment: environment)
        let second = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: home), environment: environment)

        XCTAssertTrue(first.settings === second.settings, "설정이 창마다 따로면 나중에 쓴 쪽이 조용히 이긴다")
        XCTAssertTrue(first.clipboard === second.clipboard, "창 A에서 ⌘C → 창 B에서 ⌘V가 다중 창의 핵심 시나리오다")
        XCTAssertTrue(first.fullDiskAccess === second.fullDiskAccess, "권한은 프로세스 단위 사실이다")
        XCTAssertTrue(first.environment === second.environment)
    }

    /// 공유 설정 변경은 **다른 창의 화면까지** 닿아야 한다(사용자 결정: 즉시 전 창 동기화).
    /// 실제 배선은 `MainWindow`의 `.onChange`이고, 여기서는 그것이 부르는 동기화 API를 검증한다.
    func testShowHiddenChange_syncsIntoOtherWindow() throws {
        let environment = makeEnvironment()
        let root = try makeTempDirectory()

        let first = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)
        let second = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)
        XCTAssertFalse(second.directory.showHidden)

        first.toggleHiddenItems()
        second.syncShowHiddenFromSettings()

        XCTAssertTrue(second.directory.showHidden, "숨김 설정이 다른 창에 반영되지 않으면 두 창이 서로 다른 규칙으로 보인다")
        XCTAssertTrue(second.tree.showHidden)
        // 동기화가 설정에 되쓰면 창들 사이에서 무한 왕복이 된다.
        XCTAssertTrue(environment.settings.showHidden)
    }

    func testSortChange_syncsIntoOtherWindow() throws {
        let environment = makeEnvironment()
        let root = try makeTempDirectory()

        let first = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)
        let second = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)

        first.applySort(FileSortDescriptor(key: .size, ascending: false))
        second.syncSortFromSettings()

        XCTAssertEqual(second.directory.sortDescriptor, FileSortDescriptor(key: .size, ascending: false))
        XCTAssertEqual(environment.settings.sortDescriptor, FileSortDescriptor(key: .size, ascending: false))
    }

    /// **회귀 (reviewer m3)** — 즐겨찾기를 토글한 창은 `addFavorite`에서 이미 트리를 다시 만든다.
    /// 그 직후 도착하는 `.onChange(of: settings.favoritePaths)`가 같은 일을 또 하면
    /// `startReveal`이 방금 시작한 `revealTask`를 취소·재시작한다(창 N개면 N+1회).
    /// 스냅샷이 같으면 동기화는 아무 일도 하지 않아야 한다.
    func testFavoritesSync_isNoOpOnTheWindowThatMadeTheChange() throws {
        let environment = makeEnvironment()
        let root = try makeTempDirectory()
        let folder = root.appendingPathComponent("Alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let author = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)
        let observer = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)

        author.addFavorite(folder)
        let revisionAfterAuthorChange = author.tree.sectionsRevision

        // 조작한 창: `.onChange`가 도착해도 이미 반영했으므로 다시 만들지 않는다.
        author.syncFavoritesFromSettings()
        XCTAssertEqual(
            author.tree.sectionsRevision, revisionAfterAuthorChange,
            "조작한 창에서 동기화가 또 돌면 방금 시작한 reveal이 즉시 취소·재시작된다"
        )

        // 다른 창: 아직 반영 전이므로 정확히 1회 반영한다.
        let observerRevisionBefore = observer.tree.sectionsRevision
        observer.syncFavoritesFromSettings()
        XCTAssertNotEqual(
            observer.tree.sectionsRevision, observerRevisionBefore,
            "다른 창은 즐겨찾기 변경을 반영해야 한다"
        )
        let observerRevisionAfter = observer.tree.sectionsRevision
        observer.syncFavoritesFromSettings()
        XCTAssertEqual(observer.tree.sectionsRevision, observerRevisionAfter, "두 번째 동기화는 무동작이어야 한다")
    }

    // MARK: - (d) 한 창의 stop()이 다른 창을 죽이지 않는다

    /// 옛 `SingleWindowSceneTests`가 봉인으로 막으려던 **바로 그 결함**.
    /// 창 2개 중 하나를 닫아도 남은 창의 클립보드/FDA 감시는 살아 있어야 한다.
    func testClosingOneWindow_keepsSharedObserversAliveForTheOther() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("UniFinderTest-MultiWindow-\(UUID().uuidString)"))
        let environment = makeEnvironment(pasteboard: pasteboard)
        let root = try makeTempDirectory()
        let file = root.appendingPathComponent("cut-me.txt")
        try Data("x".utf8).write(to: file)

        let first = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)
        let second = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: root), environment: environment)
        first.start()
        second.start()
        XCTAssertEqual(environment.openWindowCount, 2)

        // 창 하나를 닫는다.
        first.stop()
        XCTAssertEqual(environment.openWindowCount, 1)
        XCTAssertTrue(environment.isOpen(second.windowID))

        // 남은 창에서 잘라내기 → 다른 앱이 클립보드를 덮어씀 → 앱 복귀.
        // 파스트보드 감시가 끊겼다면 cut 표시가 영영 남는다.
        let clipboard = environment.clipboard
        clipboard.cut([file])
        XCTAssertEqual(clipboard.cutURLs, [file])

        pasteboard.clearContents()
        pasteboard.setString("from another app", forType: .string)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { clipboard.cutURLs.isEmpty }
        XCTAssertTrue(
            clipboard.cutURLs.isEmpty,
            "창 하나를 닫았다고 공유 파스트보드 감시가 풀리면 남의 클립보드 위에 우리 cut 표시가 영영 남는다"
        )

        second.stop()
        XCTAssertEqual(environment.openWindowCount, 0, "마지막 창이 닫히면 열린 창은 0이 된다")
    }

    /// FDA 감시가 **마지막 창이 닫힐 때만** 풀리는지 — 소유자 집합의 핵심 계약.
    func testFullDiskAccessObservation_survivesUntilLastWindowCloses() async {
        let probe = SwitchableProbe(.denied)
        let suiteName = "UniFinderTests-MultiWindow-FDA-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("테스트 전용 UserDefaults suite 생성 실패")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let fda = FullDiskAccessModel(probe: probe, defaults: defaults, opener: { _ in true })
        let windowA = UUID()
        let windowB = UUID()

        fda.start(owner: windowA)
        fda.postpone()
        fda.start(owner: windowB)

        // 창 A를 닫는다 — 관측자는 B가 아직 들고 있으므로 살아 있어야 한다.
        fda.stopObservingActivation(owner: windowA)

        probe.set(.readable)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { fda.status == .granted }
        XCTAssertEqual(
            fda.status, .granted,
            "창 하나를 닫았다고 공유 FDA 감시가 풀리면 남은 창에서 '허용 → 복귀 시 자동 감지'가 죽는다"
        )

        // 마지막 창까지 닫히면 그때 풀린다.
        fda.stopObservingActivation(owner: windowB)
        probe.set(.denied)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil(timeout: 0.5) { fda.status == .denied }
        XCTAssertEqual(fda.status, .granted, "마지막 소유자가 빠지면 감시가 해제돼 더는 갱신되지 않는다")
    }

    /// 같은 창이 `onAppear`를 여러 번 받아도(뷰 아이덴티티 변화) 소유자 집합은 멱등이어야 한다 —
    /// `Int` 참조 카운트였다면 여기서 값이 드리프트해 감시가 영영 풀리지 않거나 일찍 풀린다.
    func testOwnerSet_isIdempotentForRepeatedRegistration() {
        let environment = makeEnvironment()
        let windowID = UUID()

        environment.register(windowID)
        environment.register(windowID)
        environment.register(windowID)
        XCTAssertEqual(environment.openWindowCount, 1)

        environment.unregister(windowID)
        environment.unregister(windowID)
        XCTAssertEqual(environment.openWindowCount, 0)
        XCTAssertFalse(environment.hasOpenWindows)
    }

    // MARK: - FDA 온보딩 시트 소유권 (필수4)

    /// 시트는 **한 창만** 띄운다. 게이팅이 없으면 열린 창 전부가 같은 시트를 동시에 띄운다.
    func testOnboardingSheet_hasSingleOwnerAndSuccession() {
        let environment = makeEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let first = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: home), environment: environment)
        let second = MainWindowRoot.makeWindowModel(seed: WindowSeed(folderURL: home), environment: environment)

        first.start()
        second.start()

        XCTAssertTrue(first.isOnboardingPresenter, "첫 등록 창이 시트 소유 창이다")
        XCTAssertFalse(second.isOnboardingPresenter, "두 창이 동시에 같은 시트를 띄우면 안 된다")

        // 소유 창이 닫히면 다음 창이 승계한다.
        first.stop()
        XCTAssertTrue(second.isOnboardingPresenter, "소유 창이 닫혔는데 승계가 없으면 시트를 띄울 창이 사라진다")

        second.stop()
        XCTAssertNil(environment.onboardingPresenterID)
    }

    // MARK: - 지원

    private final class SwitchableProbe: ProtectedPathProbing, @unchecked Sendable {

        let candidates: [ProtectedPath] = [.directory("/probe/multiwindow")]

        private let lock = NSLock()
        private var outcome: ProbeOutcome

        init(_ outcome: ProbeOutcome) { self.outcome = outcome }

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

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("UniFinderMultiWindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
