import XCTest
@testable import UniFinder

/// M3 T0 — `FileListBridge.Coordinator.ReloadReason`에 `.contentsUpdated` 케이스 추가 (m3-impl B5).
///
/// **가정하는 프로덕션 변경**: 기존 `.itemsChanged`는 `appliedItemCount != itemCount`로만 판정하므로
/// "1개 추가 + 1개 삭제로 count가 동일"한 FSEvents 갱신을 놓친다(B5 명시 지적). 이를 신호하기 위해
/// `DirectoryModel`이 `applyExternalUpdate(_:)`(→ `DirectoryModelInPlaceUpdateTests` 참고) 호출마다
/// 증가시키는 별도 카운터(`contentsRevision`)를 도입하고, `reloadReason`이 이를 받아
/// **`.directoryChanged`(스크롤 초기화 + 첫 행 강제 선택)보다는 약하고, `.itemsChanged`보다는
/// 우선하는** `.contentsUpdated` 케이스로 판정한다고 가정한다:
///
/// ```swift
/// static func reloadReason(
///     appliedRevision: Int, revision: Int,
///     appliedContentsRevision: Int, contentsRevision: Int,
///     appliedItemCount: Int, itemCount: Int,
///     appliedClipboardRevision: Int, clipboardRevision: Int
/// ) -> ReloadReason
/// ```
///
/// ralph 구현이 다른 시그니처/이름을 택하면 verifier가 이 파일을 실제 계약에 맞춰 조정해야 한다.
/// `updateNSView`의 `.contentsUpdated` 분기는 `reloadData()`만 하고 `scrollRowToVisible(0)`·
/// `selectFirstRowIfNeeded()`는 절대 호출하면 안 된다(B5 수용 기준 — 스크롤/선택 유지).
@MainActor
final class FileListBridgeContentsUpdatedReloadReasonTests: XCTestCase {

    /// count는 동일하지만 내용이 바뀐 FSEvents 갱신 — `.itemsChanged`(count 비교)로는 못 잡는 케이스.
    func testReloadReason_contentsRevisionChanged_withSameItemCount_yieldsContentsUpdated() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 3,
            revision: 3,
            appliedContentsRevision: 1,
            contentsRevision: 2,
            appliedItemCount: 5,
            itemCount: 5,
            appliedClipboardRevision: 0,
            clipboardRevision: 0
        )
        XCTAssertEqual(
            reason, .contentsUpdated,
            "count가 같아도 contentsRevision이 바뀌면 갱신이 반영되어야 한다(B5 — 1개 추가+1개 삭제 케이스)"
        )
    }

    /// 전체 폴더 이동(`.directoryChanged`)이 항상 `.contentsUpdated`보다 우선해야 한다
    /// (스크롤 초기화·첫 행 선택 규칙은 폴더가 실제로 바뀐 경우에만 적용).
    func testReloadReason_directoryRevisionChanged_winsOverContentsUpdated() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 3,
            revision: 4,
            appliedContentsRevision: 1,
            contentsRevision: 2,
            appliedItemCount: 5,
            itemCount: 5,
            appliedClipboardRevision: 0,
            clipboardRevision: 0
        )
        XCTAssertEqual(reason, .directoryChanged)
    }

    /// 아무 카운터도 안 바뀌면 여전히 `.none`.
    func testReloadReason_nothingChanged_remainsNone() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 3,
            revision: 3,
            appliedContentsRevision: 1,
            contentsRevision: 1,
            appliedItemCount: 5,
            itemCount: 5,
            appliedClipboardRevision: 0,
            clipboardRevision: 0
        )
        XCTAssertEqual(reason, .none)
    }

    /// 클립보드만 바뀐 기존 M2 회귀가 `.contentsUpdated` 도입 이후에도 유지되는지.
    func testReloadReason_clipboardOnly_stillYieldsClipboardChanged_regression() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 3,
            revision: 3,
            appliedContentsRevision: 1,
            contentsRevision: 1,
            appliedItemCount: 5,
            itemCount: 5,
            appliedClipboardRevision: 1,
            clipboardRevision: 2
        )
        XCTAssertEqual(reason, .clipboardChanged, "M2의 클립보드 전용 갱신 판정이 회귀하면 안 됨(architect B6)")
    }
}
