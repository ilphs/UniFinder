import AppKit
import XCTest
@testable import UniFinder

/// **M2 백로그 회귀** — `.`으로 시작하는 이름 확인 알림을 `NSAlert.runModal()`(앱-모달)에서
/// 윈도우 시트로 전환한 건.
///
/// 전환의 유일한 함정은 **B23 보류 규약의 해제 시점**이다: 앱-모달 런루프는 사용자가 버튼을
/// 누를 때까지 `runModal()` 안에서 블록되므로 `defer`가 곧 "알림이 닫힌 시점"이었지만, 시트는
/// 런루프를 블록하지 않아 표시 요청 직후 함수가 반환한다. 같은 자리에서 `defer`로 풀면
/// 시트가 뜨자마자 가드가 풀려 사용자가 시트를 보고 있는 사이에 뒤쪽 목록이 갈아엎힌다.
///
/// 그래서 여기서는 "시트 수명 = 보류 수명"인지를 시트 대역(gate)으로 정확히 고정한다.
@MainActor
final class AppModelHiddenNameConfirmationTests: TempDirectoryTestCase {

    /// 시트를 대신하는 대역. `resume`이 불릴 때까지 `await`가 멈춰 있어 시트 수명을 그대로 흉내낸다.
    @MainActor
    private final class SheetGate {

        private var continuation: CheckedContinuation<Bool, Never>?
        private(set) var isWaiting = false

        func wait() async -> Bool {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                self.continuation = continuation
                self.isWaiting = true
            }
        }

        func resume(_ value: Bool) {
            let pending = continuation
            continuation = nil
            isWaiting = false
            pending?.resume(returning: value)
        }
    }

    private func makeAppModel(startURL: URL, watcher: DirectoryWatcher) -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelHiddenName-\(UUID().uuidString)")!),
            operations: FileOperations(),
            directoryWatcher: watcher,
            startURL: startURL
        )
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - B23: 보류 수명이 시트 수명과 정확히 맞물리는가

    func testExternalChange_whileConfirmationSheetIsUp_staysDeferredUntilTheSheetCloses() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        try Fixture.makeFile(in: folder, name: "a.txt")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)

        model.navigate(to: folder, source: .toolbar)
        await waitUntil { model.directory.items.count == 1 }

        // 시트가 떠 있는 동안(= gate가 열리기 전까지) 보류가 유지되어야 한다.
        let gate = SheetGate()
        let confirmation = Task { @MainActor in
            await model.withExternalRefreshSuspended { await gate.wait() }
        }
        await waitUntil { gate.isWaiting }
        XCTAssertTrue(gate.isWaiting, "시트 대역이 열리지 않아 보류 구간을 검증할 수 없음")

        try Fixture.makeFile(in: folder, name: "b.txt")
        watcher.noteChange()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(
            model.directory.items.count, 1,
            "시트가 떠 있는 동안 목록이 갈아엎히면 안 된다(B23). `defer`로 해제하면 여기서 2가 된다"
        )

        // 시트가 닫히면 보류된 변경이 1회 반영된다.
        gate.resume(true)
        let confirmed = await confirmation.value
        XCTAssertTrue(confirmed, "시트 응답이 그대로 호출자에게 전달되어야 한다")

        await waitUntil { model.directory.items.count == 2 }
        XCTAssertEqual(model.directory.items.count, 2, "시트가 닫힌 뒤에는 보류된 변경이 반영되어야 한다")
    }

    /// 취소로 닫힌 시트도 보류를 반드시 해제해야 한다(해제를 빠뜨리면 목록이 영영 스테일해진다).
    func testExternalChange_afterCancelledConfirmationSheet_isStillFlushed() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        try Fixture.makeFile(in: folder, name: "a.txt")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)

        model.navigate(to: folder, source: .toolbar)
        await waitUntil { model.directory.items.count == 1 }

        let gate = SheetGate()
        let confirmation = Task { @MainActor in
            await model.withExternalRefreshSuspended { await gate.wait() }
        }
        await waitUntil { gate.isWaiting }

        try Fixture.makeFile(in: folder, name: "b.txt")
        watcher.noteChange()
        try await Task.sleep(nanoseconds: 200_000_000)
        gate.resume(false)

        let confirmed = await confirmation.value
        XCTAssertFalse(confirmed)
        await waitUntil { model.directory.items.count == 2 }
        XCTAssertEqual(model.directory.items.count, 2, "취소로 닫혀도 보류는 풀려야 한다")
    }

    // MARK: - 확인이 필요한 조건 (UI설계 §7.2)

    func testNeedsHiddenNameConfirmation_onlyForDotPrefixWhileHiddenItemsAreOff() {
        XCTAssertTrue(AppModel.needsHiddenNameConfirmation(".gitignore", showHidden: false))
        XCTAssertFalse(
            AppModel.needsHiddenNameConfirmation(".gitignore", showHidden: true),
            "숨김 표시가 켜져 있으면 항목이 그대로 보이므로 확인할 이유가 없다"
        )
        XCTAssertFalse(AppModel.needsHiddenNameConfirmation("readme.txt", showHidden: false))
    }

    // MARK: - 윈도우가 없을 때의 폴백 (헤드리스/테스트)

    /// 윈도우가 없거나 보이지 않으면 확인 없이 진행한다 — 시트를 붙일 곳이 없기 때문이다.
    func testRename_toHiddenName_withoutVisibleWindow_proceedsWithoutConfirmation() async throws {
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)
        let file = try Fixture.makeFile(in: testRoot, name: "note.txt")
        XCTAssertNil(model.focusBroker.window, "이 테스트의 전제는 시트를 붙일 윈도우가 없는 상태다")

        model.rename(file, to: ".note.txt")

        let renamed = testRoot.appendingPathComponent(".note.txt")
        await waitUntil { FileManager.default.fileExists(atPath: renamed.path) }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: renamed.path),
            "확인 UI를 띄울 수 없는 상태에서 rename이 조용히 삼켜지면 안 된다"
        )
    }

    // MARK: - 실제 시트 경로 (앱-모달이 아님을 고정)

    /// 실 윈도우에 확인 UI가 **시트로** 붙는지 확인한다.
    ///
    /// `runModal()`로 되돌아가면 메인 스레드가 알림 안에서 블록되므로 `window.attachedSheet`가
    /// 영영 채워지지 않는다 — 이 테스트가 그 회귀를 잡는 유일한 지점이다.
    func testRename_toHiddenName_presentsSheetAndCancelSkipsRename() async throws {
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)
        let file = try Fixture.makeFile(in: testRoot, name: "note.txt")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let listView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(listView)
        window.orderFront(nil)
        model.focusBroker.register(listView: listView)
        try XCTSkipUnless(window.isVisible, "헤드리스 환경이라 시트를 붙일 수 없음")

        model.rename(file, to: ".note.txt")
        await waitUntil { window.attachedSheet != nil }
        guard let sheet = window.attachedSheet else {
            return XCTFail("확인 UI가 시트로 붙지 않았다(앱-모달 `runModal`로 회귀했을 가능성)")
        }

        // "취소"(두 번째 버튼) — rename이 수행되지 않아야 한다.
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "확인 시트에서 취소했는데 rename이 수행되면 안 된다"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: testRoot.appendingPathComponent(".note.txt").path))
        window.orderOut(nil)
    }
}
