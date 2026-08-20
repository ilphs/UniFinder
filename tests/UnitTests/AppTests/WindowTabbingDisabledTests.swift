import AppKit
import XCTest
@testable import UniFinder

/// 창 탭 비활성화 회귀 가드 (2026-08-20).
///
/// `WindowGroup`은 macOS가 자동으로 창 탭(Window > Merge All Windows)을 붙여준다.
/// 실측(2026-08-20)해 보니 탭 제목이 전부 "UniFinder"로 고정되고, 새 탭은 항상 홈에서
/// 열리며, 탭바 표시 자체가 사용자의 시스템 설정에 좌우됐다 — 셋 다 `WindowGroup` 자동 탭의
/// 구조적 한계라 고칠 수 없었다(자세한 근거는 `UniFinderApp.init()` 주석 참조).
///
/// `UniFinderApp.init()`이 `NSWindow.allowsAutomaticWindowTabbing = false`를 설정해 끄는데,
/// 이 값은 **전역 정적 상태**라 실수로 지워지거나 다른 초기화 경로가 되돌려도 컴파일 에러가
/// 나지 않는다. 이 테스트가 유일한 방어선이다.
final class WindowTabbingDisabledTests: XCTestCase {

    /// **`UniFinderApp`을 인스턴스화해 확인한다** — `init()`이 도는 시점에만 값이 반영되므로,
    /// 정적 프로퍼티를 직접 assert하면 이 테스트가 다른 테스트보다 먼저 돈다는 우연에 결과가
    /// 좌우된다. 앱 타입을 직접 만들어 그 시점을 통제한다.
    @MainActor
    func testAppInit_disablesAutomaticWindowTabbing() {
        _ = UniFinderApp()

        XCTAssertFalse(
            NSWindow.allowsAutomaticWindowTabbing,
            "창 탭이 켜져 있으면 제목이 전부 \"UniFinder\"인 탭이 다시 생긴다 — UniFinderApp.init() 참조"
        )
    }
}
