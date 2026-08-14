import AppKit
import XCTest
@testable import UniFinder

/// `ConflictSheetPresenter` 회귀 테스트 (M2 백로그 B3/B4 — M3 D&D 선처리).
///
/// - **B3**: 알 수 없는 모달 응답이 "둘 다 유지"(파일을 하나 더 만드는 **부작용 있는** 선택)로
///   떨어지면, 시트가 예상 밖 경로로 닫힐 때 사용자가 고르지도 않은 사본이 생긴다.
///   M3에서 취소 UI가 늘어나면 그 경로도 함께 늘어나므로 안전한 기본값(`.cancel`)으로 고정한다.
/// - **B4**: 이미 결과가 정해진 요청에 뒤늦게 도착한 취소가 `cancelledIDs`에 영구히 남으면
///   조작 1건당 상태가 누적된다(M3에서 취소는 상시 동작).
@MainActor
final class ConflictSheetPresenterTests: XCTestCase {

    private func makeConflict() -> FileConflict {
        FileConflict(
            kind: .copy,
            source: URL(fileURLWithPath: "/tmp/uf-conflict-src/note.txt"),
            destination: URL(fileURLWithPath: "/tmp/uf-conflict-dst/note.txt"),
            sourceSize: 10,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationSize: 20,
            destinationModifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            remainingCount: 0
        )
    }

    /// 헤드리스 프레젠터 — 윈도우가 없으면 시트를 띄우지 않고 즉시 `.cancel`로 응답한다.
    private func makeHeadlessPresenter() -> ConflictSheetPresenter {
        let presenter = ConflictSheetPresenter()
        presenter.windowProvider = { nil }
        return presenter
    }

    /// 메인 액터에 예약된 후속 작업(`onCancel`의 `Task { @MainActor }` 홉)을 처리시킨다.
    private func drainMainActor() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - B3: 알 수 없는 응답의 기본값

    func testResolution_knownButtons_mapToDeclaredOrder() {
        XCTAssertEqual(ConflictSheetPresenter.resolution(for: .alertFirstButtonReturn), .replace)
        XCTAssertEqual(ConflictSheetPresenter.resolution(for: .alertSecondButtonReturn), .cancel)
        XCTAssertEqual(ConflictSheetPresenter.resolution(for: .alertThirdButtonReturn), .skip)
        XCTAssertEqual(ConflictSheetPresenter.resolution(for: ConflictSheetPresenter.alertFourthButtonReturn), .keepBoth)
    }

    /// 4번째 버튼 상수(`alertThirdButtonReturn + 1`)가 실제 알림 버튼 배열과 어긋나면
    /// "둘 다 유지"가 조용히 `.cancel`로 바뀐다 — 상수와 실제 배열을 함께 고정한다.
    func testMakeAlert_buttonOrderMatchesFourthButtonConstant() {
        let alert = ConflictSheetPresenter.makeAlert(for: makeConflict())

        XCTAssertEqual(alert.buttons.map(\.title), ["덮어쓰기", "취소", "건너뛰기", "둘 다 유지"], "UI설계 §7.1 버튼 배열이 바뀌었다")
        XCTAssertEqual(alert.buttons.count, 4)
        XCTAssertEqual(
            ConflictSheetPresenter.alertFourthButtonReturn.rawValue,
            NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1,
            "4번째 버튼 응답 규약(AppKit)이 어긋나면 \"둘 다 유지\"가 default로 새어 나간다"
        )
    }

    /// B3 본체: 명시적 케이스가 아닌 응답은 **부작용 없는** `.cancel`이어야 한다.
    func testResolution_unknownResponses_areCancelNotKeepBoth() {
        let unknownResponses: [NSApplication.ModalResponse] = [
            .abort,
            .stop,
            .continue,
            .OK,
            .cancel,
            NSApplication.ModalResponse(rawValue: 12_345),
            NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 2)
        ]

        for response in unknownResponses {
            XCTAssertEqual(
                ConflictSheetPresenter.resolution(for: response),
                .cancel,
                "알 수 없는 응답(\(response.rawValue))이 파일을 만드는 \"둘 다 유지\"로 떨어졌다(B3)"
            )
        }
    }

    // MARK: - B4: 취소 상태 누수

    func testResolve_withoutWindow_resolvesToCancelAndLeavesNoState() async {
        let presenter = makeHeadlessPresenter()
        let conflict = makeConflict()

        let decision = await presenter.resolve(conflict)

        XCTAssertEqual(decision.resolution, .cancel)
        XCTAssertEqual(presenter.liveRequestCount, 0, "끝난 요청이 진행 중으로 남아있다")
        XCTAssertEqual(presenter.pendingCancellationMarkerCount, 0, "취소 표식이 남았다(B4 누수)")
    }

    /// 정상 종료된 뒤 도착한 취소는 흔적을 남기지 않아야 한다.
    /// (`onCancel`은 `Task { @MainActor }` 한 홉을 거치므로 continuation 재개 **뒤에** 도착할 수 있다)
    func testLateCancellationAfterRequestSettled_doesNotAccumulateState() async {
        let presenter = makeHeadlessPresenter()

        for _ in 0..<3 {
            _ = await presenter.resolve(makeConflict())
        }
        XCTAssertEqual(presenter.liveRequestCount, 0)

        // 이미 끝난 요청 ID + 존재하지 않는 ID로 뒤늦은 취소가 도착한다.
        for id in 1...6 {
            presenter.cancel(id: id)
        }

        XCTAssertEqual(
            presenter.pendingCancellationMarkerCount,
            0,
            "끝난 요청에 도착한 취소가 영구히 쌓인다 — 조작 1건당 누수(B4)"
        )
        XCTAssertEqual(presenter.liveRequestCount, 0)
    }

    /// 시트가 뜨기 전에 취소가 먼저 도착하는 경쟁은 계속 흡수되어야 한다(표식이 소비되고 남지 않음).
    func testResolve_cancelledBeforeSheet_isAbsorbedAndCleanedUp() async {
        let presenter = makeHeadlessPresenter()
        let conflict = makeConflict()

        let task = Task { await presenter.resolve(conflict) }
        task.cancel()
        let decision = await task.value
        await drainMainActor()

        XCTAssertEqual(decision.resolution, .cancel, "취소된 조작의 충돌 질의는 .cancel로 재개되어야 함")
        XCTAssertEqual(presenter.pendingCancellationMarkerCount, 0, "선취소 표식이 소비되지 않고 남았다(B4 누수)")
        XCTAssertEqual(presenter.liveRequestCount, 0)
    }

    /// 반복 조작에서 상태가 누적되지 않는지 — 누수는 "1건"이 아니라 "쌓임"이 문제다.
    func testRepeatedCancelledResolves_doNotGrowInternalState() async {
        let presenter = makeHeadlessPresenter()

        for _ in 0..<20 {
            let task = Task { [presenter] in await presenter.resolve(makeConflict()) }
            task.cancel()
            _ = await task.value
        }
        await drainMainActor()

        XCTAssertEqual(presenter.pendingCancellationMarkerCount, 0, "취소 표식이 조작마다 누적된다(B4)")
        XCTAssertEqual(presenter.liveRequestCount, 0, "끝난 요청이 진행 중으로 누적된다")
    }
}
