import XCTest
@testable import UniFinder

/// M3 T2 — `AppModel.cancelCurrentOperation()` (m3-impl B20).
///
/// **가정하는 프로덕션 API**: `AppModel`에 `func cancelCurrentOperation()`가 추가되고, 내부는
/// 진행 중인 `operationTask`(private)를 취소한다. 취소가 실제로 하위 `Task`/`FileOperating`
/// 호출까지 전파되어 **행 없이 끝나야 한다**(취소 의미론: 완료분 유지, 롤백 없음).
///
/// `GatedFileOperating`(Support)로 조작 진행을 인위적으로 붙잡아 취소 타이밍을 결정적으로 만든다.
@MainActor
final class AppModelCancelCurrentOperationTests: XCTestCase {

    private func makeAppModel(operations: any FileOperating) -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelCancelTests-\(UUID().uuidString)")!),
            operations: operations,
            startURL: FileManager.default.temporaryDirectory
        )
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 진행 중인 조작이 없을 때 호출해도 크래시/부작용이 없어야 한다(방어적 API).
    func testCancelCurrentOperation_withNoActiveOperation_doesNothing() {
        let appModel = makeAppModel(operations: GatedFileOperating())

        appModel.cancelCurrentOperation()

        XCTAssertNil(appModel.operationProgressText)
    }

    /// 취소가 대기 중인 하위 작업의 continuation까지 재개시켜 **행 없이** 끝나는지(B20 핵심).
    func testCancelCurrentOperation_midOperation_completesWithoutHang() async throws {
        let gated = GatedFileOperating()
        await gated.setGated(true)
        let appModel = makeAppModel(operations: gated)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelCancelTests-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        appModel.drop([FileManager.default.temporaryDirectory.appendingPathComponent("a.txt")], into: destination, operation: .move)

        // 조작이 게이트에 걸려 "진행 중" 상태가 될 때까지 기다린다.
        await waitUntil { await gated.moveCallCount > 0 }
        XCTAssertNotNil(appModel.operationProgressText, "진행 중 상태 표시가 안 나타났다 — 취소 타이밍을 재현할 수 없음")

        appModel.cancelCurrentOperation()

        // 취소가 `release()` 없이도 하위 continuation을 재개시켜야 한다 — 재개되지 않으면
        // 아래 대기가 타임아웃까지 실패한다(= 행 재현).
        await waitUntil { appModel.operationProgressText == nil }

        XCTAssertNil(appModel.operationProgressText, "취소 후에도 진행 표시가 남아있다 — 조작이 행 상태(B20 위반)")
        let resumedCount = await gated.cancellationResumedCount
        XCTAssertEqual(resumedCount, 1, "대기 중 continuation이 취소로 재개되지 않았다(행/누수)")
    }

    /// 취소 후 조작 슬롯이 풀려 다음 조작을 바로 받을 수 있어야 한다(영구 잠금 방지).
    func testCancelCurrentOperation_freesOperationSlot_forSubsequentOperation() async throws {
        let gated = GatedFileOperating()
        await gated.setGated(true)
        let appModel = makeAppModel(operations: gated)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelCancelTests-dest2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        appModel.drop([FileManager.default.temporaryDirectory.appendingPathComponent("a.txt")], into: destination, operation: .move)
        await waitUntil { await gated.moveCallCount > 0 }

        appModel.cancelCurrentOperation()
        await waitUntil { appModel.operationProgressText == nil }

        // 취소된 조작은 게이트가 걸린 채로 남아 있지만(release 안 함), 다음 조작은 새 호출이라 곧바로 진행되어야 한다.
        appModel.drop([FileManager.default.temporaryDirectory.appendingPathComponent("b.txt")], into: destination, operation: .move)
        await waitUntil { await gated.moveCallCount > 1 }

        let finalCallCount = await gated.moveCallCount
        XCTAssertEqual(finalCallCount, 2, "취소 후 다음 조작이 슬롯을 얻지 못했다(영구 잠금)")
    }
}
