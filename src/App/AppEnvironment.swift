import Foundation
import Observation

/// **앱 전역**으로 하나여야 하는 상태의 소유자 (다중 창 T2).
///
/// `AppModel`이 "윈도우 1개분"으로 되돌아가면서(창마다 탐색·트리·히스토리를 독립으로 갖는다)
/// 창을 넘어 하나여야 하는 것들만 여기로 옮겼다:
///
/// - `settings` — 숨김/정렬/즐겨찾기/폭. 같은 `UserDefaults`를 두 인스턴스가 각각 캐시하면
///   한 창의 변경이 다른 창의 인스턴스에는 반영되지 않고, 나중에 쓴 쪽이 조용히 이긴다.
/// - `clipboard` — 창 A에서 ⌘C 하고 창 B에서 ⌘V 하는 것이 다중 창의 주요 사용 시나리오다.
/// - `fullDiskAccess` — 권한은 프로세스 단위 사실이다. 창마다 프로브를 돌릴 이유가 없다.
///
/// **창 수명주기도 여기서 센다**(`openWindowIDs`). 두 곳이 이 값을 근거로 동작한다:
/// - `AppModel.stop()`의 QuickLook 패널 정리 — **마지막 창이 닫힐 때만** 닫는다.
///   무조건 닫으면 배경 창을 닫는 순간 다른 창이 띄운 미리보기 패널이 함께 사라진다.
/// - FDA 온보딩 시트의 **표시 소유권**(`onboardingPresenterID`) — `isOnboardingPresented`는
///   공유 인스턴스의 `Bool` 하나라, 게이팅이 없으면 열려 있는 **모든 창이 동시에** 같은 시트를 띄운다.
@MainActor
@Observable
final class AppEnvironment {

    /// 앱이 쓰는 공유 인스턴스. **`UniFinderApp`(정확히는 `MainWindowRoot`)에서만 주입한다.**
    ///
    /// 테스트가 이걸 기본값으로 집어가면 `UserDefaults.standard`/`NSPasteboard.general`을
    /// 공유해 테스트끼리 오염된다 — `AppModel`의 `environment` 파라미터 기본값이 `nil`이고
    /// nil일 때 **격리된 새 환경**을 만드는 이유가 그것이다.
    static let shared = AppEnvironment()

    let settings: AppSettings
    let clipboard: ClipboardModel
    let fullDiskAccess: FullDiskAccessModel

    /// 업데이트 확인 (후속 T3). **앱 전역 1개여야 하는 이유**는 위 셋과 같다 —
    /// 창마다 두면 앱을 켤 때 창 수만큼 요청이 나가고 결과 알림도 창 수만큼 뜬다.
    let update: UpdateCheckModel

    /// 열려 있는 창들 — **등록 순서를 유지**한다(온보딩 시트 소유권 승계 순서가 곧 이 순서다).
    ///
    /// `Set`이 아니라 배열인 이유: "첫 등록 창", "그 창이 닫히면 다음 창"이라는 승계 규칙에
    /// 순서가 필요하다. 중복 등록은 `register`가 걸러 멱등성을 유지한다.
    private(set) var openWindowIDs: [UUID] = []

    /// 테스트가 격리된 환경을 만들 수 있도록 전부 주입 가능하게 둔다.
    init(
        settings: AppSettings? = nil,
        clipboard: ClipboardModel? = nil,
        fullDiskAccess: FullDiskAccessModel? = nil,
        update: UpdateCheckModel? = nil
    ) {
        self.settings = settings ?? AppSettings()
        self.clipboard = clipboard ?? ClipboardModel()
        self.fullDiskAccess = fullDiskAccess ?? FullDiskAccessModel()
        self.update = update ?? UpdateCheckModel()
    }

    // MARK: - 창 수명주기

    /// 창이 열렸음을 기록한다. **같은 창이 몇 번을 불러도 멱등**이다 —
    /// SwiftUI는 뷰 아이덴티티가 바뀌면 `onAppear`를 추가로 부를 수 있다(권장 7).
    ///
    /// **순서의 정확한 의미** (reviewer 지적): 신규 등록은 항상 배열 꼬리에 붙는다. 그래서 창이
    /// `stop()` → `start()` 왕복을 겪으면(창을 닫았다 Dock에서 다시 여는 경로) 그 창은 꼬리로
    /// 이동하고 `onboardingPresenterID`가 다른 창으로 넘어간다. 즉 이 순서가 뜻하는 것은
    /// "앱 시작 이후 처음 열린 창"이 아니라 **"가장 오래전에 등록되어 그 뒤로 재등록되지 않은 창"**이다.
    /// 소유권이 그렇게 넘어가도 규약(= 시트를 띄우는 창이 정확히 하나)은 그대로 성립한다.
    func register(_ windowID: UUID) {
        guard !openWindowIDs.contains(windowID) else { return }
        openWindowIDs.append(windowID)
    }

    /// 창이 닫혔음을 기록한다. 등록된 적 없는 식별자는 조용히 무시한다(멱등).
    func unregister(_ windowID: UUID) {
        openWindowIDs.removeAll { $0 == windowID }
    }

    var hasOpenWindows: Bool { !openWindowIDs.isEmpty }

    var openWindowCount: Int { openWindowIDs.count }

    func isOpen(_ windowID: UUID) -> Bool { openWindowIDs.contains(windowID) }

    /// FDA 온보딩 시트를 띄울 **소유 창**. 첫 등록 창이고, 그 창이 닫히면 다음 창이 승계한다.
    ///
    /// `FullDiskAccessModel.isOnboardingPresented`는 공유 인스턴스의 `Bool` 하나다.
    /// `OnboardingSheet`의 `.sheet(isPresented:)`는 **창마다 붙는 모디파이어**라 게이팅이 없으면
    /// 열린 창 전부가 같은 시트를 동시에 띄운다. 배너(`shouldShowBanner`)는 반대로
    /// **전 창 표시가 맞다** — 제한 모드는 모든 창에 해당하는 사실이기 때문이다.
    var onboardingPresenterID: UUID? { openWindowIDs.first }

    func isOnboardingPresenter(_ windowID: UUID) -> Bool {
        onboardingPresenterID == windowID
    }

    /// **앱 전역 알림**(업데이트 확인 결과)을 그릴 소유 창 (후속 T3).
    ///
    /// 온보딩 시트와 완전히 같은 문제다: `UpdateCheckModel.presentation`은 공유 인스턴스의 값
    /// 하나인데 `.alert`는 창마다 붙는 모디파이어라, 게이팅이 없으면 열린 창 전부가 같은 알림을
    /// 동시에 띄운다. 규칙도 같게 둔다(첫 등록 창 → 닫히면 다음 창이 승계) — 규칙이 둘로 갈리면
    /// "왜 이 창은 시트를 띄우고 저 창은 알림을 띄우나"를 나중에 아무도 설명하지 못한다.
    var globalAlertPresenterID: UUID? { openWindowIDs.first }

    func isGlobalAlertPresenter(_ windowID: UUID) -> Bool {
        globalAlertPresenterID == windowID
    }

    /// **앱 전역 알림을 실제로 그릴 창이 있는지** (reviewer major #2).
    ///
    /// 알림은 소유 창(`globalAlertPresenterID`)의 `.alert` 모디파이어가 그린다. 창이 하나도
    /// 없으면 소유 창도 없고, 그때 `UpdateCheckModel.presentation`에 결과를 넣어봐야 **아무 데도
    /// 뜨지 않는다** — 사용자는 `Check for Updates…`를 눌렀는데 새 버전 안내도, 실패 안내도
    /// 못 받는다(그 사이 상태만 남아 다음에 창을 열 때 뒤늦게 튀어나온다).
    ///
    /// 그래서 **결과를 말할 수 없으면 애초에 묻지도 않는다**: 창이 0개면 메뉴 항목을 비활성으로
    /// 내린다(File/View/Go의 `hasNoFocusedWindow` 가드와 같은 패턴). 대안이던 "창이 없을 때만
    /// `NSAlert`를 직접 띄운다"는 결과 표시 경로가 둘로 갈리고(알림 문구·버튼 구성을 두 벌
    /// 유지해야 한다) `UpdateCheckAlertModifier`가 유일한 표시 지점이라는 규약도 깨진다.
    var canPresentGlobalAlert: Bool { globalAlertPresenterID != nil }
}
