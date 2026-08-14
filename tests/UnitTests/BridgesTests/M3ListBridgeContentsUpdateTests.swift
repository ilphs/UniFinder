import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// M3 T0/B5 — 브릿지의 `.contentsUpdated` 판정 (ralph 작성).
///
/// FSEvents 갱신이 `.directoryChanged`로 판정되면 매 갱신마다 `scrollRowToVisible(0)` +
/// 첫 행 강제 선택이 돌아 수용 기준("스크롤·선택 유지")이 무너진다. 판정 자체를 순수 함수로
/// 고정해 회귀를 막는다.
@MainActor
final class M3ListBridgeContentsUpdateTests: XCTestCase {

    func testReloadReason_contentsRevisionChangedAlone_isContentsUpdated() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 7,
            revision: 7,
            appliedContentsRevision: 3,
            contentsRevision: 4,
            appliedItemCount: 5,
            itemCount: 5,
            appliedClipboardRevision: 1,
            clipboardRevision: 1
        )
        XCTAssertEqual(
            reason, .contentsUpdated,
            "외부 변경은 스크롤·첫 행 선택을 건드리지 않는 별도 갱신이어야 한다(B5)"
        )
    }

    /// 1개 추가 + 1개 삭제 — `items.count`가 같아 `.itemsChanged`로는 잡히지 않는 경우.
    func testReloadReason_sameItemCountButContentsChanged_stillReloads() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 2,
            revision: 2,
            appliedContentsRevision: 9,
            contentsRevision: 10,
            appliedItemCount: 12,
            itemCount: 12,
            appliedClipboardRevision: 0,
            clipboardRevision: 0
        )
        XCTAssertEqual(reason, .contentsUpdated, "개수가 같다는 이유로 갱신이 누락되면 안 된다(B5)")
    }

    /// 폴더 전환이 외부 변경보다 우선한다(전환은 어차피 전체를 다시 그린다).
    func testReloadReason_directoryChangeWins_overContentsUpdate() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 1,
            revision: 2,
            appliedContentsRevision: 0,
            contentsRevision: 1,
            appliedItemCount: 3,
            itemCount: 3,
            appliedClipboardRevision: 0,
            clipboardRevision: 0
        )
        XCTAssertEqual(reason, .directoryChanged)
    }

    /// 외부 변경이 클립보드 표시 변화보다 우선한다(둘 다 reloadData지만 선택 반영이 필요).
    func testReloadReason_contentsUpdateWins_overClipboardChange() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 1,
            revision: 1,
            appliedContentsRevision: 0,
            contentsRevision: 1,
            appliedItemCount: 3,
            itemCount: 3,
            appliedClipboardRevision: 0,
            clipboardRevision: 1
        )
        XCTAssertEqual(reason, .contentsUpdated)
    }

    /// M2 호출부 회귀: `contentsRevision`을 넘기지 않는 기존 판정은 그대로 동작해야 한다.
    func testReloadReason_withoutContentsRevision_keepsM2Behavior() {
        XCTAssertEqual(
            FileListBridge.Coordinator.reloadReason(
                appliedRevision: 4,
                revision: 4,
                appliedItemCount: 2,
                itemCount: 3,
                appliedClipboardRevision: 0,
                clipboardRevision: 0
            ),
            .itemsChanged
        )
    }
}
