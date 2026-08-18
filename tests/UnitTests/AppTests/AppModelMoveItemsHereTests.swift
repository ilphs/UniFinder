import AppKit
import XCTest
@testable import UniFinder

/// "Move Items Here"(⌥⌘V) — 2026-08-18 D단계.
///
/// Finder에는 파일 잘라내기가 없고 ⌘C 후 ⌥⌘V로 이동한다. UniFinder는 Win10식 ⌘X를 유지한 채
/// 이 진입점만 얹었다. 여기서 고정하는 계약은 셋이다.
/// 1. **세 가지 클립보드 상태 모두에서 이동한다** — 내부 cut / 내부 copy / 외부(소유권 상실).
/// 2. `paste(into:)`와 **같은 경로**를 탄다 (`runOperation` 직렬화 + `applyOperationResult` 단일 경유점).
/// 3. cut 소비 규칙은 `paste`와 **동일**하다 — "실제로 하나라도 옮겨졌는가"만 본다.
@MainActor
final class AppModelMoveItemsHereTests: TempDirectoryTestCase {

    /// 테스트마다 전용 파스트보드 — `.general`을 쓰면 사용자 클립보드를 덮어쓴다.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("UniFinderMoveHereTest-\(UUID().uuidString)"))
    }

    private func makeAppModel(operations: GatedFileOperating, clipboard: ClipboardModel) -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelMoveHere-\(UUID().uuidString)")!),
            operations: operations,
            clipboard: clipboard,
            startURL: testRoot
        )
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 3케이스: 어떤 클립보드 상태에서도 "이동"이어야 한다

    /// (1) 내부 cut 클립보드 — ⌘V와 결과가 같다.
    func testMoveItemsHere_withInternalCutClipboard_performsMove() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let operations = GatedFileOperating()
        await operations.configureResult(OperationResult(produced: [destination.appendingPathComponent("a.txt")]))
        let clipboard = ClipboardModel(pasteboard: makePasteboard())
        let model = makeAppModel(operations: operations, clipboard: clipboard)

        model.cut([source])
        model.moveClipboardItems(into: destination)
        await waitUntil { !model.isOperationInProgress }

        let moves = await operations.moveCallCount
        let copies = await operations.copyCallCount
        let lastDestination = await operations.lastMoveDestination
        XCTAssertEqual(moves, 1, "⌥⌘V가 이동을 수행하지 않았다")
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(lastDestination, destination)
    }

    /// (2) 내부 copy 클립보드 — ⌘V였다면 복사였을 상황에서 **이동**해야 한다. 이게 ⌥⌘V의 존재 이유다.
    func testMoveItemsHere_withInternalCopyClipboard_performsMoveNotCopy() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let operations = GatedFileOperating()
        await operations.configureResult(OperationResult(produced: [destination.appendingPathComponent("a.txt")]))
        let clipboard = ClipboardModel(pasteboard: makePasteboard())
        let model = makeAppModel(operations: operations, clipboard: clipboard)

        model.copy([source])
        XCTAssertEqual(model.clipboard.pasteSource().operation, .copy, "전제 확인 — ⌘V였다면 복사였을 상태")

        model.moveClipboardItems(into: destination)
        await waitUntil { !model.isOperationInProgress }

        let moves = await operations.moveCallCount
        let copies = await operations.copyCallCount
        XCTAssertEqual(moves, 1, "copy 클립보드에서 ⌥⌘V가 이동하지 않았다")
        XCTAssertEqual(copies, 0, "⌥⌘V가 복사로 새어 나갔다")
    }

    /// (3) 외부 클립보드(파스트보드 소유권 상실) — **안전 기본값을 의도적으로 뚫는 자리**다.
    ///
    /// `pasteSource()`는 소유권을 잃으면 `.copy`로 강등한다(외부 내용에 cut 의미론을 추론으로
    /// 적용하지 않는다는 규약). ⌥⌘V는 사용자가 "이동"을 명시한 명령이므로 그 강등을 통과시킨다 —
    /// Finder도 외부 클립보드에 대해 똑같이 이동한다. 이 테스트가 그 예외를 못 박는다.
    func testMoveItemsHere_withForeignClipboard_stillPerformsMove() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let pasteboard = makePasteboard()
        let operations = GatedFileOperating()
        await operations.configureResult(OperationResult(produced: [destination.appendingPathComponent("a.txt")]))
        let clipboard = ClipboardModel(pasteboard: pasteboard)
        let model = makeAppModel(operations: operations, clipboard: clipboard)

        // 다른 앱이 쓴 것과 같은 상태 — `ClipboardModel`을 거치지 않고 파스트보드에 직접 쓴다.
        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSURL])
        XCTAssertFalse(clipboard.ownsPasteboard, "전제 확인 — 소유권을 잃은 상태여야 한다")
        XCTAssertEqual(clipboard.pasteSource().operation, .copy, "전제 확인 — 강등이 살아 있어야 한다")

        model.moveClipboardItems(into: destination)
        await waitUntil { !model.isOperationInProgress }

        let moves = await operations.moveCallCount
        let copies = await operations.copyCallCount
        XCTAssertEqual(moves, 1, "외부 클립보드에서 ⌥⌘V가 이동하지 않았다")
        XCTAssertEqual(copies, 0)
    }

    /// 강등 규칙 자체는 `pasteSource()`에 **그대로 남아 있어야 한다** — ⌘V는 여전히 복사다.
    func testForeignClipboard_plainPasteStillCopies() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let pasteboard = makePasteboard()
        let operations = GatedFileOperating()
        let clipboard = ClipboardModel(pasteboard: pasteboard)
        let model = makeAppModel(operations: operations, clipboard: clipboard)

        // 내부에서 cut을 세운 **뒤** 다른 앱이 파스트보드를 덮어쓴 상황.
        model.cut([source])
        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSURL])

        model.paste(into: destination)
        await waitUntil { !model.isOperationInProgress }

        let copies = await operations.copyCallCount
        let moves = await operations.moveCallCount
        XCTAssertEqual(copies, 1, "소유권을 잃은 클립보드의 ⌘V가 이동으로 새어 나갔다")
        XCTAssertEqual(moves, 0)
    }

    // MARK: - cut 소비 규칙 (`paste`와 동일해야 한다)

    /// 하나라도 옮겨졌으면 소비한다 — copy 클립보드였어도 마찬가지다.
    /// (원본이 그 자리에서 사라졌으므로 남겨두면 이어지는 ⌘V가 `sourceMissing`만 반복한다)
    func testMoveItemsHere_whenMoveSucceeds_consumesClipboardEvenIfItWasCopy() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let operations = GatedFileOperating()
        await operations.configureResult(OperationResult(produced: [destination.appendingPathComponent("a.txt")]))
        let model = makeAppModel(operations: operations, clipboard: ClipboardModel(pasteboard: makePasteboard()))

        model.copy([source])
        model.moveClipboardItems(into: destination)
        await waitUntil { !model.isOperationInProgress }

        XCTAssertTrue(model.clipboard.items.isEmpty, "이동에 성공했는데 클립보드가 남았다")
        XCTAssertNil(model.clipboard.operation)
    }

    /// 하나도 못 옮겼으면(전부 실패/취소/skipped) **유지**한다 — `paste`와 같은 게이팅이다.
    func testMoveItemsHere_whenNothingMoved_keepsClipboard() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let operations = GatedFileOperating()
        await operations.configureResult(OperationResult(failures: [OperationFailure(url: source, error: .accessDenied)]))
        let model = makeAppModel(operations: operations, clipboard: ClipboardModel(pasteboard: makePasteboard()))

        model.cut([source])
        model.moveClipboardItems(into: destination)
        await waitUntil { !model.isOperationInProgress }

        XCTAssertEqual(model.clipboard.items, [source], "전부 실패했는데 클립보드를 비우면 잘라낸 항목을 잃는다")
        XCTAssertEqual(model.clipboard.operation, .cut)
    }

    // MARK: - 빈 클립보드

    func testMoveItemsHere_withEmptyClipboard_doesNothing() async throws {
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let operations = GatedFileOperating()
        let model = makeAppModel(operations: operations, clipboard: ClipboardModel(pasteboard: makePasteboard()))

        model.moveClipboardItems(into: destination)
        await waitUntil(timeout: 0.5) { false }

        let moves = await operations.moveCallCount
        let copies = await operations.copyCallCount
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(copies, 0)
    }
}
