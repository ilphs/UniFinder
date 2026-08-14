import XCTest
@testable import UniFinder

/// M3 T2 — 진행률 오버레이 상태 (m3-impl B18·B19). ralph 작성.
///
/// 고정하는 계약:
/// - **지연 표시**: 시작 즉시가 아니라 임계 시간 이후에만 보인다(소용량 작업 깜빡임 금지)
/// - **항목 수 기준 문구**(B19) — 바이트·속도는 Phase 2라 이 모델에 존재해서도 안 된다
/// - 종료 시 상태가 완전히 정리된다(다음 조작에 잔상이 남지 않음)
@MainActor
final class OperationProgressModelTests: XCTestCase {

    private func progress(_ kind: FileOperationKind, _ completed: Int, _ total: Int, name: String? = nil) -> OperationProgress {
        OperationProgress(
            kind: kind,
            completed: completed,
            total: total,
            current: name.map { URL(fileURLWithPath: "/tmp/progress-tests/\($0)") }
        )
    }

    // MARK: - 지연 표시 (B18)

    func testBegin_doesNotShowOverlayImmediately() {
        let model = OperationProgressModel(presentationDelay: .milliseconds(200))

        model.begin(kind: .copy)

        XCTAssertFalse(model.isVisible, "시작 즉시 뜨면 소용량 작업마다 오버레이가 깜빡인다(B18)")
    }

    func testShortOperation_finishedBeforeDelay_neverShowsOverlay() async throws {
        let model = OperationProgressModel(presentationDelay: .milliseconds(200))

        model.begin(kind: .copy)
        model.update(progress(.copy, 1, 1))
        model.finish()
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertFalse(model.isVisible, "임계 시간 전에 끝난 작업은 끝내 표시되면 안 된다")
    }

    func testLongOperation_showsOverlayAfterDelay() async throws {
        let model = OperationProgressModel(presentationDelay: .milliseconds(100))

        model.begin(kind: .copy)
        model.update(progress(.copy, 3, 512, name: "a.txt"))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(model.isVisible, "1초(테스트에서는 100ms)를 넘긴 작업은 표시되어야 한다")
        model.finish()
        XCTAssertFalse(model.isVisible)
    }

    // MARK: - 항목 수 기준 문구 (B19)

    func testItemCountText_usesItemCountsOnly_notBytes() {
        let model = OperationProgressModel()
        model.begin(kind: .copy)

        model.update(progress(.copy, 128, 512))

        XCTAssertEqual(model.itemCountText, "128/512 항목", "진행 문구는 항목 수 기준이어야 한다(B19 — 바이트는 Phase 2)")
        XCTAssertEqual(model.title, FileOperationKind.copy.progressLabel)
        XCTAssertEqual(model.fraction ?? 0, 0.25, accuracy: 0.0001)
    }

    func testFraction_isNilBeforeAnyTick_soBarStaysIndeterminate() {
        let model = OperationProgressModel()
        model.begin(kind: .move)

        XCTAssertNil(model.fraction, "총 개수를 모르는 구간은 불확정 막대여야 한다")
        XCTAssertEqual(model.itemCountText, "")
    }

    func testUpdate_tracksCurrentItemName() {
        let model = OperationProgressModel()
        model.begin(kind: .move)

        model.update(progress(.move, 2, 10, name: "photo.png"))

        XCTAssertEqual(model.currentName, "photo.png")
    }

    // MARK: - 취소 표시 / 정리

    func testMarkCancelling_onlyAppliesWhileAnOperationIsActive() {
        let model = OperationProgressModel()

        model.markCancelling()
        XCTAssertFalse(model.isCancelling, "진행 중인 조작이 없으면 취소 상태가 켜지면 안 된다")

        model.begin(kind: .trash)
        model.markCancelling()
        XCTAssertTrue(model.isCancelling)
    }

    func testFinish_resetsEverything_soNextOperationStartsClean() async throws {
        let model = OperationProgressModel(presentationDelay: .milliseconds(50))
        model.begin(kind: .copy)
        model.update(progress(.copy, 5, 10, name: "x.txt"))
        model.markCancelling()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(model.isVisible)

        model.finish()

        XCTAssertFalse(model.isVisible)
        XCTAssertFalse(model.isCancelling)
        XCTAssertEqual(model.itemCountText, "")
        XCTAssertNil(model.currentName)
        XCTAssertNil(model.fraction)
    }

    /// 연속 조작: 이전 조작의 지연 타이머가 다음 조작의 표시를 앞당기면 안 된다.
    func testBegin_restartsDelayTimer_forEachOperation() async throws {
        let model = OperationProgressModel(presentationDelay: .milliseconds(200))
        model.begin(kind: .copy)
        try await Task.sleep(nanoseconds: 150_000_000)
        model.finish()

        model.begin(kind: .move)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(model.isVisible, "새 조작은 자기 임계 시간을 새로 채워야 한다")
        model.finish()
    }
}
