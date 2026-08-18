import AppKit
import XCTest
@testable import UniFinder

/// **M2 백로그 회귀** — 잘라내기(cut) 클립보드 소거 타이밍.
///
/// 예전 `paste(into:)`는 이동 결과와 무관하게 완료 콜백에서 무조건 `clipboard.clear()`를 불렀다.
/// 그래서 이동이 **전부 실패**했거나 사용자가 충돌 시트에서 **취소**했을 때도 클립보드가 비워져,
/// 사용자는 잘라낸 항목을 잃고 처음부터 다시 잘라내야 했다.
///
/// 판정 기준은 "실제로 하나라도 이동에 성공했는가"(`produced`)다.
/// 부분 성공은 비운다 — 남은 항목을 다시 붙여넣어도 이미 이동된 원본은 그 자리에 없어
/// `sourceMissing`만 반복되므로, 클립보드를 유지하는 편이 더 혼란스럽다.
@MainActor
final class AppModelPasteClipboardTests: TempDirectoryTestCase {

    private func makeClipboard() -> ClipboardModel {
        ClipboardModel(pasteboard: NSPasteboard(name: NSPasteboard.Name("UniFinderPasteTest-\(UUID().uuidString)")))
    }

    private func makeAppModel(operations: GatedFileOperating, clipboard: ClipboardModel) -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelPaste-\(UUID().uuidString)")!),
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

    /// cut → paste 1회를 끝까지 돌리고, 조작 완료(= 완료 콜백 실행) 시점까지 기다린다.
    private func runCutAndPaste(
        result: OperationResult,
        cutting sources: [URL],
        into destination: URL
    ) async -> AppModel {
        let operations = GatedFileOperating()
        await operations.configureResult(result)
        let clipboard = makeClipboard()
        let model = makeAppModel(operations: operations, clipboard: clipboard)

        model.cut(sources)
        XCTAssertEqual(model.clipboard.operation, .cut, "붙여넣기 전에 cut 상태가 서 있어야 한다")

        model.paste(into: destination)
        await waitUntil { !model.isOperationInProgress }
        return model
    }

    // MARK: - 전부 실패 / 취소 — 클립보드를 유지해야 한다

    func testPaste_afterCutWhenAllMovesFail_keepsClipboardSoUserNeedNotCutAgain() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let failed = OperationResult(failures: [OperationFailure(url: source, error: .accessDenied)])

        let model = await runCutAndPaste(result: failed, cutting: [source], into: destination)

        XCTAssertEqual(model.clipboard.items, [source], "전부 실패했는데 클립보드를 비우면 잘라낸 항목을 잃는다")
        XCTAssertEqual(model.clipboard.operation, .cut, "cut 표시(50% 불투명)도 유지되어야 한다")
    }

    func testPaste_afterCutWhenCancelledInConflictSheet_keepsClipboard() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let cancelled = OperationResult(isCancelled: true)

        let model = await runCutAndPaste(result: cancelled, cutting: [source], into: destination)

        XCTAssertEqual(model.clipboard.items, [source], "취소했는데 클립보드가 비면 사용자가 다시 잘라내야 한다")
        XCTAssertEqual(model.clipboard.operation, .cut)
    }

    /// 같은 폴더에 붙여넣기(no-op)처럼 **옮겨진 것이 하나도 없는** 경우도 소비로 치지 않는다.
    func testPaste_afterCutWhenEverythingWasSkipped_keepsClipboard() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let skipped = OperationResult(skipped: [source])

        let model = await runCutAndPaste(result: skipped, cutting: [source], into: testRoot)

        XCTAssertEqual(model.clipboard.items, [source])
        XCTAssertEqual(model.clipboard.operation, .cut)
    }

    // MARK: - 성공 / 부분 성공 — 클립보드를 비운다

    func testPaste_afterCutWhenAllMovesSucceed_clearsClipboard() async throws {
        let first = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let second = try Fixture.makeFile(in: testRoot, name: "b.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let moved = OperationResult(produced: [
            destination.appendingPathComponent("a.txt"),
            destination.appendingPathComponent("b.txt"),
        ])

        let model = await runCutAndPaste(result: moved, cutting: [first, second], into: destination)

        XCTAssertTrue(model.clipboard.items.isEmpty, "cut은 1회 소비 후 비운다(m2-impl T4)")
        XCTAssertNil(model.clipboard.operation)
    }

    func testPaste_afterCutWithPartialSuccess_clearsClipboard() async throws {
        let moved = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let failed = try Fixture.makeFile(in: testRoot, name: "b.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let partial = OperationResult(
            produced: [destination.appendingPathComponent("a.txt")],
            failures: [OperationFailure(url: failed, error: .accessDenied)]
        )

        let model = await runCutAndPaste(result: partial, cutting: [moved, failed], into: destination)

        XCTAssertTrue(
            model.clipboard.items.isEmpty,
            "이미 이동된 원본이 섞인 클립보드를 남겨두면 재붙여넣기가 sourceMissing만 반복한다"
        )
    }

    // MARK: - 복사는 어떤 결과에서도 클립보드를 건드리지 않는다

    func testPaste_afterCopy_neverClearsClipboardEvenOnFailure() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let operations = GatedFileOperating()
        await operations.configureResult(OperationResult(failures: [OperationFailure(url: source, error: .accessDenied)]))
        let model = makeAppModel(operations: operations, clipboard: makeClipboard())

        model.copy([source])
        model.paste(into: destination)
        await waitUntil { !model.isOperationInProgress }

        XCTAssertEqual(model.clipboard.items, [source], "복사는 반복 붙여넣기가 정상 동작이다")
        XCTAssertEqual(model.clipboard.operation, .copy)
        let copyCount = await operations.copyCallCount
        XCTAssertEqual(copyCount, 1)
    }
}
