import AppKit
import QuickLookUI
import SwiftUI
import XCTest
@testable import UniFinder

/// **M3 리뷰 blocker 2/3 회귀** — 창을 닫았다가 다시 여는 왕복. ralph 작성.
///
/// `AppModel.stop()`은 감시자 4종(볼륨·클립보드·FDA·FSEvents)을 해제하고, Dock에서 창을 다시 열면
/// `AppModel.start()`가 전부 다시 걸어야 한다. 감시자 하나라도 재등록되지 않으면 그 시점부터
/// 해당 기능이 **영구히** 죽는데, 화면에는 아무 증상도 나타나지 않아 눈으로는 잡히지 않는다.
@MainActor
final class AppModelLifecycleRestartTests: TempDirectoryTestCase {

    /// 감지 결과를 도중에 바꿀 수 있는 프로브 (FullDiskAccessModelTests와 같은 대역).
    private final class SwitchableProbe: ProtectedPathProbing, @unchecked Sendable {

        let candidates: [ProtectedPath] = [.directory("/probe/restart")]

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

    /// 테스트 전용 `UserDefaults` suite (전역 설정 오염 금지). 정리는 teardown 블록이 맡는다.
    ///
    /// - Note: `TempDirectoryTestCase.setUpWithError`가 nonisolated라 MainActor 프로퍼티를
    ///   셋업에서 채울 수 없다. 그래서 각 테스트가 필요할 때 만든다.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "UniFinderTests-Restart-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("테스트 전용 UserDefaults suite 생성 실패")
            return .standard
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 창 닫기 → Dock에서 다시 열기 → 시스템 설정에서 허용 → 앱 복귀.
    /// 이 왕복에서 FDA 재감지가 살아 있어야 T5 수용 기준이 성립한다(blocker 2).
    func testReopeningWindow_restoresFullDiskAccessDetection() async {
        let defaults = makeDefaults()
        let probe = SwitchableProbe(.denied)
        let fullDiskAccess = FullDiskAccessModel(probe: probe, defaults: defaults, opener: { _ in true })
        let model = AppModel(
            settings: AppSettings(defaults: defaults),
            fullDiskAccess: fullDiskAccess,
            startURL: testRoot
        )

        model.start()
        fullDiskAccess.postpone()
        XCTAssertEqual(fullDiskAccess.status, .denied)

        // 창 닫힘 → Dock 아이콘으로 재오픈
        model.stop()
        model.start()

        // 사용자가 시스템 설정에서 허용하고 앱으로 복귀
        probe.set(.readable)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { fullDiskAccess.status == .granted }

        XCTAssertEqual(
            fullDiskAccess.status, .granted,
            "창을 다시 연 뒤 didBecomeActive 재감지가 죽으면 '허용 → 복귀 시 자동 감지'가 성립하지 않는다(blocker 2)"
        )
    }

    /// 형제 감시자도 같은 왕복에서 되살아나는지 — FDA만 다른 가드 규칙을 쓴 것이 blocker 2의 원인이었다.
    /// (여기서 클립보드가 통과하고 FDA만 실패한다면, 그 차이가 곧 결함이다)
    func testReopeningWindow_restoresClipboardObservation() async throws {
        let defaults = makeDefaults()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("UniFinderTest-Restart-\(UUID().uuidString)"))
        let clipboard = ClipboardModel(pasteboard: pasteboard)
        let model = AppModel(
            settings: AppSettings(defaults: defaults),
            clipboard: clipboard,
            startURL: testRoot
        )
        let file = try Fixture.makeFile(in: testRoot, name: "cut-me.txt")

        model.start()
        model.stop()
        model.start()

        clipboard.cut([file])
        XCTAssertEqual(clipboard.cutURLs, [file])

        // 다른 앱이 클립보드를 덮어쓴 뒤 앱으로 복귀 → cut 표시가 해제되어야 한다.
        pasteboard.clearContents()
        pasteboard.setString("from another app", forType: .string)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { clipboard.cutURLs.isEmpty }

        XCTAssertTrue(
            clipboard.cutURLs.isEmpty,
            "재오픈 후 파스트보드 관측이 죽으면 남의 클립보드 위에 우리 cut 표시가 영영 남는다"
        )
    }

    // MARK: - blocker 3: QuickLook 패널이 해제된 객체를 가리킨 채 남지 않는다

    /// `QLPreviewPanel.dataSource`/`delegate`는 SDK 헤더상 `@property(assign)`이라 zeroing weak가 아니다.
    /// 패널이 열린 채 창이 닫히면 Coordinator가 해제되는데 패널은 dangling 포인터를 들고 남아
    /// 다음 콜백에서 크래시한다 — `dismantleNSView`가 반드시 끊어야 한다.
    func testDismantleNSView_detachesQuickLookPanelFromCoordinator() throws {
        let defaults = makeDefaults()
        guard let panel = QLPreviewPanel.shared() else {
            throw XCTSkip("이 환경에서 QLPreviewPanel 공유 인스턴스를 만들 수 없음")
        }
        addTeardownBlock {
            MainActor.assumeIsolated {
                panel.dataSource = nil
                panel.delegate = nil
            }
        }

        var selection = Set<URL>()
        let bridge = FileListBridge(
            items: [],
            revision: 1,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: defaults),
            onOpen: { _ in },
            onNavigateUp: {},
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: { _ in }
        )
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView()
        coordinator.tableView = tableView
        tableView.quickLookController = coordinator

        // 패널이 열려 이 Coordinator를 datasource/delegate로 붙든 상태(= beginPreviewPanelControl 이후)
        panel.dataSource = coordinator
        panel.delegate = coordinator

        // 창이 닫힌다
        FileListBridge.dismantleNSView(NSScrollView(), coordinator: coordinator)

        XCTAssertNil(
            panel.dataSource,
            "해제될 Coordinator를 패널이 계속 가리키면 다음 콜백에서 dangling 포인터로 크래시한다(blocker 3)"
        )
        XCTAssertNil(panel.delegate, "delegate도 같은 이유로 끊어야 한다(blocker 3)")
    }
}
