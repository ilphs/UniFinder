import AppKit
import SwiftUI

@main
@MainActor
struct UniFinderApp: App {

    /// **창 탭을 껐다** (2026-08-20, multiwindow-impl §4.2 뒤집기).
    ///
    /// `WindowGroup`을 쓰면 macOS가 창 탭(Window > Merge All Windows)을 자동으로 붙여준다.
    /// M3에서는 "탭은 Phase 2 항목인데 OS 기본 동작으로 공짜로 얻는다"며 수용했지만, 실측
    /// (2026-08-20)해 보니 세 가지가 구조적으로 막혀 있었다:
    ///
    /// - **탭 제목이 전부 "UniFinder"다** — SwiftUI `WindowGroup`은 창 제목을 앱 이름으로
    ///   고정하고, 탭 제목은 창 제목을 그대로 따른다. 탭을 4개 열면 어느 탭이 어느 폴더인지
    ///   구분할 방법이 없다.
    /// - **새 탭은 항상 홈에서 열린다** — 탭바의 `+`는 `WindowGroup`의 기본값 생성 경로를 타고,
    ///   그 경로에는 "현재 창의 폴더를 시드로 넘겨라"를 끼워 넣을 지점이 없다(`WindowSeed`는
    ///   ⌘N에서만 명시적으로 채워진다). ⌘N(현재 폴더)과 `+`(항상 홈)의 동작이 어긋난다.
    /// - **탭바 표시 자체가 사용자의 시스템 설정(`일반 > 탭으로 열기`)에 좌우된다** — 기본 설정
    ///   머신에서는 탭바가 처음부터 숨어 있어 `+` 버튼조차 보이지 않는다. 즉 이 기능이 있는지
    ///   없는지가 우리가 아니라 macOS 환경설정에 달려 있었다.
    ///
    /// 셋 다 "탭이 아직 완성되지 않았다"가 아니라 SwiftUI `WindowGroup` 자동 탭의 **구조적 한계**다.
    /// 제목·시작 폴더까지 잡으려면 창 생성 시점에 AppKit으로 개입해야 하고(`addTabbedWindow` 등),
    /// 그러면 `AppModel`이 "창 1개 = 탭 1개"에서 "창 셸 + 탭별 세션"으로 갈라져야 한다 — 다중 창
    /// T3/T6a가 세운 "창 1개 = `AppModel` 1개" 전제(직렬화 범위·`focusedSceneValue` 라우팅·
    /// onboarding presenter 판정이 전부 여기 기댄다) 전체를 다시 설계해야 하는 규모다.
    ///
    /// 어중간한 상태로 있는 것의 대가(제목 오해·"새 탭이 왜 홈에서 열리나" 문의·설정 의존적 표시)가
    /// 지금 얻는 것(창 여러 개를 하나로 묶는 것 하나)보다 크다고 판단해 껐다. **탭을 다시 하려면**
    /// 이 플래그를 지우는 대신, 창 생성 파이프라인을 AppKit으로 가져와 제목·시작 폴더를 함께
    /// 잡는 별도 작업으로 다시 설계할 것 — `NSWindow.tabbingMode`/`addTabbedWindow` 경로다.
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

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
        // **창 탭은 껐다** (위 `init()` 참조) — `WindowGroup`을 쓰는 이유는 시드 기반 창 생성이지
        // 탭이 아니다.
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

        // **Get Info 창** (후속 T5 / D7) — 대상별로 창이 하나씩 열린다.
        //
        // `WindowGroup(for:)`은 **같은 값 = 같은 창**으로 취급한다. `InfoTarget`은 URL만으로
        // 결정되는 값이라(UUID 없음) 같은 파일의 Get Info를 다시 요청하면 새 창이 생기지 않고
        // 기존 창이 앞으로 나온다 — 정확히 우리가 원하는 동작이다(`WindowSeed`와 정반대 선택).
        WindowGroup(id: Self.infoWindowID, for: InfoTarget.self) { $target in
            if let target {
                ItemInfoWindow(target: target)
            }
        }
        .defaultSize(width: 420, height: 460)
        .windowResizability(.contentMinSize)

        // **디스크 용량 창** (후속 T8 / D9) — 앱 전체에 **하나뿐**이라 `WindowGroup`이 아니라 `Window`다.
        // 볼륨 용량은 창별 상태가 아니라 머신의 사실이므로 같은 표가 여러 벌 떠 있을 이유가 없다.
        Window("Disk Capacity", id: Self.diskCapacityWindowID) {
            DiskUsageWindow()
        }
        .defaultSize(width: 480, height: 360)
    }

    /// 메인 창 그룹의 씬 식별자. `openWindow(id:value:)`가 이 값을 쓴다.
    static let mainWindowID = "main"

    /// Get Info 창 그룹의 씬 식별자 (후속 T5).
    static let infoWindowID = "info"

    /// 디스크 용량 창의 씬 식별자 (후속 T8).
    static let diskCapacityWindowID = "disk-capacity"
}
