import AppKit
import XCTest
@testable import UniFinder

/// **다중 창 지원의 가장 중요한 회귀 방어선.**
///
/// 예전 단일 창(`Window`) 설계에서 `AppModel.stop()`은 감시자 4종(FSEvents·볼륨·클립보드·FDA)을
/// 무조건 해제했다 — 창이 하나뿐이라는 전제 위에서는 안전했다. `WindowGroup`으로 전환하면
/// 그 전제가 깨진다: 창 A와 창 B가 클립보드·FDA라는 **같은 인스턴스**를 공유하는 상태에서
/// 창 A만 닫으면(`stop()`), 그 무조건 해제가 **아직 열려 있는 창 B의 감시자까지** 끊어버린다.
/// 화면에는 아무 에러도 없이 "창 B에서 폴더 내용이 더 이상 갱신되지 않는다"는 조용한 결함이 된다.
///
/// 여기서는 환경을 공유하는 두 `AppModel`(A·B)을 만들고 **A만 `stop()`**한 뒤, B의 감시자가
/// 살아 있는지 — 그리고 A의 감시자는 실제로 정지됐는지 — 를 검증한다.
@MainActor
final class WindowIsolationLifecycleTests: TempDirectoryTestCase {

    /// FDA 감지 결과를 도중에 바꿀 수 있는 프로브 (FullDiskAccessModelTests와 같은 대역).
    private final class SwitchableProbe: ProtectedPathProbing, @unchecked Sendable {
        let candidates: [ProtectedPath] = [.directory("/probe/window-isolation")]
        private let lock = NSLock()
        private var outcome: ProbeOutcome

        init(_ outcome: ProbeOutcome) { self.outcome = outcome }

        func set(_ newOutcome: ProbeOutcome) {
            lock.lock(); outcome = newOutcome; lock.unlock()
        }

        func probe(_ candidate: ProtectedPath) -> ProbeOutcome {
            lock.lock(); defer { lock.unlock() }
            return outcome
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "UniFinderTests-WindowIsolation-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            XCTFail("테스트 전용 UserDefaults suite 생성 실패")
            return .standard
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 환경을 공유하는 두 `AppModel`. 클립보드/FDA는 **같은 인스턴스**를 명시적으로 공유시킨다
    /// (실제로는 `AppEnvironment`가 이 공유를 담당하지만, 여기서는 공유 자체의 결과만
    /// 검증하면 되므로 생성자 주입으로 직접 재현한다 — `AppModelLifecycleRestartTests`와 같은 패턴).
    private func makeSharedWindows(
        probe: SwitchableProbe,
        defaults: UserDefaults,
        pasteboard: NSPasteboard
    ) -> (a: AppModel, b: AppModel, clipboard: ClipboardModel, fda: FullDiskAccessModel) {
        let settings = AppSettings(defaults: defaults)
        let clipboard = ClipboardModel(pasteboard: pasteboard)
        let fda = FullDiskAccessModel(probe: probe, defaults: defaults, opener: { _ in true })
        let environment = AppEnvironment(settings: settings, clipboard: clipboard, fullDiskAccess: fda)

        let modelA = AppModel(
            environment: environment,
            settings: settings,
            clipboard: clipboard,
            fullDiskAccess: fda,
            directoryWatcher: DirectoryWatcher(),
            startURL: testRoot
        )
        let modelB = AppModel(
            environment: environment,
            settings: settings,
            clipboard: clipboard,
            fullDiskAccess: fda,
            directoryWatcher: DirectoryWatcher(),
            startURL: testRoot
        )
        return (modelA, modelB, clipboard, fda)
    }

    // MARK: (a) 클립보드 — A만 stop해도 didBecomeActive 반응이 살아 있다

    func testStoppingOneWindow_leavesClipboardObservationAliveForOtherWindow() async throws {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("UniFinderTests-WindowIsolation-\(UUID().uuidString)"))
        let probe = SwitchableProbe(.readable)
        let (modelA, modelB, clipboard, _) = makeSharedWindows(probe: probe, defaults: defaults, pasteboard: pasteboard)
        let file = try Fixture.makeFile(in: testRoot, name: "cut-me.txt")

        modelA.start()
        modelB.start()
        clipboard.cut([file])
        XCTAssertEqual(clipboard.cutURLs, [file], "전제 확인")

        // 창 A만 닫는다 — 창 B는 여전히 열려 있다.
        modelA.stop()

        // 다른 앱이 클립보드를 덮어쓴 뒤 앱으로 복귀 → cut 표시가 해제되어야 한다(관측이 살아 있다는 증거).
        pasteboard.clearContents()
        pasteboard.setString("from another app", forType: .string)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { clipboard.cutURLs.isEmpty }

        XCTAssertTrue(
            clipboard.cutURLs.isEmpty,
            "창 A를 닫았다고 클립보드 관측이 죽으면, 아직 열려 있는 창 B에서도 외부 클립보드 변경을 못 알아챈다"
        )
        modelB.stop()
    }

    // MARK: (b) FDA — A만 stop해도 프로브 재감지가 살아 있다

    func testStoppingOneWindow_leavesFullDiskAccessDetectionAliveForOtherWindow() async {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("UniFinderTests-WindowIsolation-FDA-\(UUID().uuidString)"))
        let probe = SwitchableProbe(.denied)
        let (modelA, modelB, _, fda) = makeSharedWindows(probe: probe, defaults: defaults, pasteboard: pasteboard)

        modelA.start()
        modelB.start()
        XCTAssertEqual(fda.status, .denied, "전제 확인")

        modelA.stop()

        probe.set(.readable)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { fda.status == .granted }

        XCTAssertEqual(
            fda.status, .granted,
            "창 A를 닫았다고 FDA 재감지가 죽으면, 아직 열려 있는 창 B에서도 '허용 → 복귀 시 자동 감지'가 성립하지 않는다"
        )
        modelB.stop()
    }

    // MARK: (c)(d) directoryWatcher — 창마다 독립이므로 B는 살아 있고 A는 정지된다

    func testStoppingWindowA_stopsOnlyItsOwnDirectoryWatcher_leavingWindowBWatching() async throws {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("UniFinderTests-WindowIsolation-Watcher-\(UUID().uuidString)"))
        let probe = SwitchableProbe(.readable)
        let (modelA, modelB, _, _) = makeSharedWindows(probe: probe, defaults: defaults, pasteboard: pasteboard)

        modelA.start()
        modelB.start()
        await waitUntil { modelA.directoryWatcher.watchedURL != nil && modelB.directoryWatcher.watchedURL != nil }
        XCTAssertNotNil(modelA.directoryWatcher.watchedURL, "전제 확인")
        XCTAssertNotNil(modelB.directoryWatcher.watchedURL, "전제 확인")

        modelA.stop()

        XCTAssertNil(modelA.directoryWatcher.watchedURL, "(d) A의 감시는 정지되어야 한다")
        XCTAssertNotNil(modelB.directoryWatcher.watchedURL, "(c) B의 감시는 A를 닫아도 살아 있어야 한다")

        // B의 감시가 실제로 동작하는지 — 외부 파일 변경이 반영되는지까지 확인한다.
        let file = try Fixture.makeFile(in: testRoot, name: "created-after-A-closed.txt")
        modelB.directoryWatcher.onChange?(testRoot)
        await waitUntil { modelB.directory.items.contains { $0.url.lastPathComponent == file.lastPathComponent } }

        XCTAssertTrue(
            modelB.directory.items.contains { $0.url.lastPathComponent == file.lastPathComponent },
            "B의 directoryWatcher가 살아 있어야 외부 파일 변경이 화면에 반영된다"
        )
        modelB.stop()
    }

    // MARK: (e) 마지막 창까지 닫으면 둘 다 정지한다

    func testStoppingBothWindows_stopsBothClipboardAndFDAObservation() async throws {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("UniFinderTests-WindowIsolation-Both-\(UUID().uuidString)"))
        let probe = SwitchableProbe(.denied)
        let (modelA, modelB, clipboard, fda) = makeSharedWindows(probe: probe, defaults: defaults, pasteboard: pasteboard)
        let file = try Fixture.makeFile(in: testRoot, name: "cut-me-both.txt")

        modelA.start()
        modelB.start()
        clipboard.cut([file])

        modelA.stop()
        modelB.stop()

        // 클립보드: 둘 다 닫혔으니 didBecomeActive가 와도 더 이상 반응하면 안 된다.
        pasteboard.clearContents()
        pasteboard.setString("from another app", forType: .string)
        probe.set(.readable)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(clipboard.cutURLs, [file], "모든 창이 닫힌 뒤에는 관측이 완전히 정지되어야 한다(cut 표시가 여전히 남아 있어야 함)")
        XCTAssertEqual(fda.status, .denied, "모든 창이 닫힌 뒤에는 FDA 재감지도 정지되어야 한다")
        XCTAssertNil(modelA.directoryWatcher.watchedURL)
        XCTAssertNil(modelB.directoryWatcher.watchedURL)
    }
}
