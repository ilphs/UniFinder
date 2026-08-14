import AppKit
import XCTest
@testable import UniFinder

/// M3 T2 B20 회귀 — **충돌 시트가 실제로 화면에 떠 있는 동안** 취소가 도착해도 행(hang) 없이
/// 끝나는지 검증한다.
///
/// `ConflictSheetPresenterTests`(M2)는 창이 없는(headless) 프레젠터로 "시트가 뜨기 **전** 취소"만
/// 다룬다 — `windowProvider`가 `nil`을 돌려주면 `present(_:id:continuation:)`가 시트를 아예 띄우지
/// 않고 즉시 `.cancel`로 응답하므로, `pending[id]`(실제 대기 중 시트)가 채워지는 경로 자체가
/// 실행되지 않는다. m3-impl B20("충돌 시트 대기 중 취소해도 hang 없이 종료")이 요구하는 것은
/// 바로 그 채워진 경로 — 시트가 **실제로 대기 중**일 때의 취소다.
///
/// 이 테스트는 실 `NSWindow`를 화면에 올려 `present`가 `pending`에 항목을 등록하게 만든 뒤,
/// 버튼 클릭 대신 `cancel(id:)`를 직접 호출해 그 경로를 강제한다(M2 파일의 주석이 명시하듯
/// "테스트는 뒤늦은 취소 재현에 `cancel(id:)`를 직접 쓴다").
@MainActor
final class ConflictSheetPresenterSheetPendingCancelTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func makeConflict() -> FileConflict {
        FileConflict(
            kind: .copy,
            source: URL(fileURLWithPath: "/tmp/uf-pending-cancel/note.txt"),
            destination: URL(fileURLWithPath: "/tmp/uf-pending-cancel-dst/note.txt"),
            sourceSize: 10,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationSize: 20,
            destinationModifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            remainingCount: 0
        )
    }

    /// 시트가 실제로 뜬 뒤 `beginSheetModal`이 콜백을 등록할 시간을 준다.
    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testCancel_whileSheetIsActuallyPending_resolvesWithoutHangAndCleansUpState() async throws {
        try XCTSkipUnless(window.isVisible, "이 환경에서 윈도우가 실제로 표시되지 않아 시트 대기 경로를 재현할 수 없음")

        let presenter = ConflictSheetPresenter()
        presenter.windowProvider = { [window] in window }

        let task = Task { await presenter.resolve(makeConflict()) }

        // present()가 실행되어 pending에 항목이 등록될 때까지 기다린다(liveRequestCount로 관측).
        await waitUntil { presenter.liveRequestCount > 0 }
        XCTAssertEqual(presenter.liveRequestCount, 1, "시트가 실제로 대기 상태가 되어야 이 테스트가 의미 있다")

        task.cancel()
        let decision = await task.value

        XCTAssertEqual(decision.resolution, .cancel, "대기 중 시트에 대한 취소는 .cancel로 재개되어야 함(행 방지)")
        XCTAssertEqual(presenter.liveRequestCount, 0, "취소 후에도 진행 중으로 남아있으면 다음 조작의 상태 판단이 오염된다")
        XCTAssertEqual(presenter.pendingCancellationMarkerCount, 0, "취소 표식이 남으면 안 됨(B4)")
    }

    /// 대기 중 시트 취소가 열려 있던 알림 창을 실제로 닫는지 — 닫지 않으면 취소 후에도 화면에
    /// 응답 없는 시트가 남아 사용자가 다음 조작을 할 수 없다(체감상 hang과 동일).
    func testCancel_whileSheetIsActuallyPending_dismissesTheVisibleAlert() async throws {
        try XCTSkipUnless(window.isVisible, "이 환경에서 윈도우가 실제로 표시되지 않아 시트 대기 경로를 재현할 수 없음")

        let presenter = ConflictSheetPresenter()
        presenter.windowProvider = { [window] in window }

        let task = Task { await presenter.resolve(makeConflict()) }
        await waitUntil { presenter.liveRequestCount > 0 }
        await waitUntil { !window.sheets.isEmpty }
        XCTAssertFalse(window.sheets.isEmpty, "시트가 실제로 창에 붙어야 이 테스트가 의미 있다")

        task.cancel()
        _ = await task.value
        await waitUntil { window.sheets.isEmpty }

        XCTAssertTrue(window.sheets.isEmpty, "취소 후에도 시트 창이 화면에 남아있다 — 사용자 관점의 hang")
    }
}
