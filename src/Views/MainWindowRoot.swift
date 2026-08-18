import SwiftUI

/// `WindowGroup`의 창 1개 = `AppModel` 1개를 보장하는 경계 (다중 창 T4).
///
/// `WindowGroup`의 content 클로저에서 `MainWindow(model:)`을 직접 만들면 모델을 어디에 둘지가
/// 애매해진다 — 클로저 안에서 `AppModel()`을 부르면 뷰가 다시 그려질 때마다 새로 만들어지고,
/// 앱 레벨 `@State`에 두면 **모든 창이 같은 모델을 공유**해 창 하나를 닫는 순간 다른 창의
/// 감시자까지 끊긴다(옛 `SingleWindowSceneTests`가 봉인하려던 바로 그 결함).
///
/// 그래서 시드를 받아 `init`에서 모델을 만들고 `@State`로 붙든다.
///
/// **정확히 말하면 `init`은 여러 번 돌 수 있다** (reviewer 지적 — 주석 정정):
/// `State(initialValue:)`의 인자는 `init`이 불릴 때마다 평가되므로, SwiftUI가 같은 창의 뷰를
/// 다시 만들면 `AppModel`이 하나 더 생겼다가 버려진다. **정확성은 안전하다** — 버려진 인스턴스는
/// `start()`를 받지 못해 `AppEnvironment`에 등록되지도, 감시자를 걸지도 않는다(순수 낭비).
/// 보장되는 것은 "`@State`가 실제로 붙드는 인스턴스는 창당 정확히 1개"이고, 그것이
/// 이 타입이 세우려는 불변식이다.
struct MainWindowRoot: View {

    @State private var model: AppModel

    init(seed: WindowSeed?) {
        _model = State(initialValue: Self.makeWindowModel(seed: seed, environment: .shared))
    }

    /// 테스트가 창 없이도 "시드 → 모델" 규약을 검증할 수 있게 노출한 팩토리.
    ///
    /// - 시드의 폴더가 `nil`이면 `AppModel`이 홈으로 폴백한다(런치 창·복원 실패 경로).
    /// - 환경은 **주입받는다** — 테스트가 `.shared`를 건드리지 않게 하기 위함이다.
    ///
    /// **시드 폴더는 `nearestExistingDirectory`를 통과시킨다** (reviewer m1): 창 복원은 종료 시점의
    /// 시드를 되살리는데 그 사이 폴더가 지워졌을 수 있다. `AppModel.init`은 `normalize`만 하고
    /// 존재 가드는 `navigate()`에만 있어서, 그대로 넘기면 **`error` 상태로 멈춘 창**이 뜬다 —
    /// 앱의 다른 모든 경로가 지키는 "가장 가까운 상위 폴더로 이동"(설계서 §6)에서 여기만 빠지게 된다.
    static func makeWindowModel(seed: WindowSeed?, environment: AppEnvironment) -> AppModel {
        AppModel(
            environment: environment,
            startURL: seed?.folderURL.map(AppModel.nearestExistingDirectory)
        )
    }

    var body: some View {
        MainWindow(model: model)
    }
}
