import SwiftUI

@main
@MainActor
struct UniFinderApp: App {

    /// **윈도우 1개분의 상태**다(`AppModel` 선언 주석). 그래서 아래 씬도 `WindowGroup`이 아니라
    /// 단일 `Window`여야 한다 — 이 둘의 전제가 어긋나면 무증상 결함이 된다(M3 리뷰 권장 3).
    @State private var model = AppModel()

    var body: some Scene {
        // `WindowGroup`은 같은 상태를 공유하는 창을 여러 개 만들 수 있다. 창이 2개가 되면
        // 한 창의 `onDisappear` → `model.stop()`이 **살아 있는 다른 창의 감시자 4종**
        // (FSEvents·볼륨·클립보드·FDA)까지 전부 해제한다. 지금은 `AppCommands`가 `Cmd+N`을
        // 치워 실질적으로 봉인돼 있지만, 윈도우 상태 복원이 창을 2개 복원하면 그대로 발현한다.
        // 단일 창 불변식을 씬 타입으로 못 박아 `AppModel`의 설계 전제와 일치시킨다.
        Window("UniFinder", id: Self.mainWindowID) {
            MainWindow(model: model)
        }
        .defaultSize(width: 1080, height: 640) // UI설계 §1
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(model: model)
        }
    }

    /// 단일 메인 창의 씬 식별자.
    static let mainWindowID = "main"
}
