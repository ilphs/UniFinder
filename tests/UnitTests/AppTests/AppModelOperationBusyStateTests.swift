import XCTest
@testable import UniFinder

/// M3 T3/B12 — "조작 진행 중"이 **관측 가능한 상태**인지 (ralph 작성).
///
/// 브릿지의 `validateDrop`은 `AppModel.isOperationInProgress`를 보고 드롭을 거부한다.
/// 이 값이 `@ObservationIgnored`인 `operationTask`를 읽는 계산 속성이면 SwiftUI가 갱신 신호를
/// 받지 못해 브릿지에 **조작 시작 이전의 낡은 `false`**가 남는다 — 화면상으로는 드롭이 접수되고
/// `runOperation`은 조용히 무시하는, 사용자 입장에서 "아무 일도 안 일어남" 상태가 된다.
///
/// 그래서 상태 전이 자체를 여기서 고정한다(관측 가능성은 저장 속성이라는 사실로 보장된다).
@MainActor
final class AppModelOperationBusyStateTests: XCTestCase {

    private func makeAppModel(operations: any FileOperating) -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelBusyTests-\(UUID().uuidString)")!),
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

    func testIsOperationInProgress_isFalseWhenIdle() {
        let model = makeAppModel(operations: GatedFileOperating())

        XCTAssertFalse(model.isOperationInProgress)
    }

    func testIsOperationInProgress_becomesTrueSynchronouslyWhenOperationStarts() async throws {
        let gated = GatedFileOperating()
        await gated.setGated(true)
        let model = makeAppModel(operations: gated)
        let destination = FileManager.default.temporaryDirectory

        model.drop([destination.appendingPathComponent("a.txt")], into: destination, operation: .move)

        XCTAssertTrue(
            model.isOperationInProgress,
            "조작 시작이 같은 런루프에서 관측되지 않으면 그 사이 들어온 드롭이 접수된다(B12)"
        )

        model.cancelCurrentOperation()
        await waitUntil { !model.isOperationInProgress }
        XCTAssertFalse(model.isOperationInProgress, "조작이 끝나면 드롭을 다시 받을 수 있어야 한다")
    }

    func testIsOperationInProgress_returnsToFalseAfterNormalCompletion() async throws {
        let gated = GatedFileOperating()
        let model = makeAppModel(operations: gated)
        let destination = FileManager.default.temporaryDirectory

        model.drop([destination.appendingPathComponent("a.txt")], into: destination, operation: .copy)
        await waitUntil { !model.isOperationInProgress }

        XCTAssertFalse(model.isOperationInProgress)
        let copyCallCount = await gated.copyCallCount
        XCTAssertEqual(copyCallCount, 1)
    }
}
