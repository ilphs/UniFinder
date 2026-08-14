import SwiftUI
import XCTest
@testable import UniFinder

/// M3 리뷰 권장 3 회귀 — **창은 하나뿐**이라는 불변식을 씬 타입으로 고정한다. ralph 작성.
///
/// `AppModel`은 스스로를 "윈도우 1개분의 상태"로 선언하고(`AppModel.swift` 선언 주석),
/// `MainWindow.onDisappear`는 그 전제 위에서 감시자 4종(FSEvents·볼륨·클립보드·FDA)을 해제한다.
/// 앱 씬이 `WindowGroup`이면 같은 `AppModel`을 공유하는 창이 여러 개 생길 수 있고, 그때
/// **한 창을 닫는 것이 살아 있는 다른 창의 감시자까지 전부 끊는다** — 화면에는 아무 에러도 없이
/// "폴더 내용이 더 이상 갱신되지 않는" 상태가 된다.
///
/// 지금은 `AppCommands`의 `CommandGroup(replacing: .newItem)`이 `Cmd+N`을 치워 실질적으로
/// 봉인돼 있지만, 그건 **단축키 하나에 기댄 봉인**이다. 윈도우 상태 복원이 창을 2개 복원하면
/// 그대로 발현하므로, 봉인을 씬 타입(`Window`) 자체로 옮긴 것을 여기서 지킨다.
@MainActor
final class SingleWindowSceneTests: XCTestCase {

    /// 씬 타입 이름으로 확인한다 — `Window`/`WindowGroup`은 런타임에 창을 세어 볼 수단이
    /// 없으므로(테스트는 앱을 띄우지 않는다) 타입 자체가 유일하게 검증 가능한 근거다.
    func testMainScene_isSingleWindow_notWindowGroup() {
        let sceneType = String(describing: type(of: UniFinderApp().body))

        XCTAssertFalse(
            sceneType.contains("WindowGroup"),
            "WindowGroup은 같은 AppModel을 공유하는 창을 여러 개 만든다 — 한 창을 닫으면 다른 창의 감시자가 끊긴다(권장 3): \(sceneType)"
        )
        XCTAssertTrue(
            sceneType.contains("Window<"),
            "메인 씬은 단일 Window여야 한다: \(sceneType)"
        )
    }
}
