import SwiftUI

@main
@MainActor
struct UniFinderApp: App {

    var body: some Scene {
        // **다중 창 (T4)** — `Window` 단일 씬에서 `WindowGroup`으로 전환한다.
        //
        // 예전에 단일 창으로 못 박았던 이유는 "`AppModel`이 앱 레벨 `@State` 하나였고, 창을 늘리면
        // 그 하나를 공유해 한 창의 `onDisappear`가 살아 있는 다른 창의 감시자까지 끊는다"는 것이었다.
        // 그 전제를 뒤집었다: 이제 **창마다 `AppModel`이 하나씩** 생기고(`MainWindowRoot`),
        // 앱 전역이어야 하는 상태(설정·클립보드·FDA)만 `AppEnvironment.shared`가 소유한다.
        // 공유 감시자의 해제는 참조가 아니라 **소유자 집합**으로 판정한다(`ClipboardModel` 참조).
        //
        // **값 기반 `WindowGroup(id:for:)`을 쓰는 이유**: 새 창의 시작 폴더를 넘겨야 한다.
        // 시드에 `UUID`가 들어 있는 이유는 `WindowSeed` 주석 참조(같은 폴더로 창을 여러 개 열기 위함).
        // `defaultValue:` 오버로드라 **런치 창은 시드가 `nil`이 아니라 홈 시드**로 뜬다 —
        // 여기서 창이 안 뜨면 UI 스모크(`NavigationSmokeUITests`)가 첫 단언에서 무너진다.
        //
        // **부수 효과**: `WindowGroup`이 되면 macOS가 창 탭(Window > Merge All Windows)을
        // 자동으로 활성화한다. 의도된 수용 사항이다(multiwindow-impl §창 탭).
        WindowGroup(id: Self.mainWindowID, for: WindowSeed.self) { $seed in
            MainWindowRoot(seed: seed)
        } defaultValue: {
            WindowSeed.launchDefault()
        }
        .defaultSize(width: 1080, height: 640) // UI설계 §1
        .windowResizability(.contentMinSize)
        .commands {
            // 모델을 여기서 넘기지 않는다 — 창이 여럿이라 "어느 창의 모델인가"가 정해지지 않는다.
            // `AppCommands`가 `@FocusedValue`로 **활성 창의 모델**을 직접 집어간다(T6a).
            AppCommands()
        }
    }

    /// 메인 창 그룹의 씬 식별자. `openWindow(id:value:)`가 이 값을 쓴다.
    static let mainWindowID = "main"
}
