import SwiftUI

/// 활성 씬이 게시하는 "새로고침" 동작 — `View > Refresh`(⌘R)의 **유일한 소유자**가 집어가는 값.
///
/// **왜 필요한가** (reviewer minor #8): ⌘R을 단 항목이 두 개였다 —
/// 메뉴바의 `View > Refresh`와 Disk Usage 창 안의 `Refresh` 버튼. 같은 단축키에 소유자가 둘이면
/// 어느 쪽이 반응하는지가 메뉴 순서·포커스 상태라는 우연에 좌우된다(⌘I에서 이미 한 번 겪었고,
/// `AppCommands`의 "단축키 소유자는 정확히 하나" 원칙은 거기서 나왔다).
///
/// **해결 방식**: 단축키는 메뉴바 하나만 갖고, "무엇을 새로고침할지"는 **활성 씬이 스스로 게시**한다.
/// 메인 창은 폴더 목록을, Disk Usage 창은 볼륨 용량을 게시한다. 창 안의 버튼은 남되(마우스로
/// 누르는 길은 항상 있어야 한다 — D9) 단축키를 갖지 않는다.
///
/// 게시는 `focusedValue`가 아니라 **`focusedSceneValue`**여야 한다. 이 앱의 first responder는
/// `NSTableView`/`NSOutlineView`(AppKit 브릿지)라 SwiftUI 포커스 체인에 뷰가 없어서
/// `focusedValue`는 값을 영영 게시하지 못한다(`AppCommands` 타입 주석의 같은 함정).
struct SceneRefreshAction: Equatable {

    /// 게시자 식별자 — 창마다 달라야 한다. SwiftUI는 이 값의 `==`로 게시 여부를 판단하는데,
    /// 창 두 개가 같은 id를 쓰면 포커스가 옮겨가도 **이전 창의 클로저가 남는다**.
    let id: String

    private let action: @MainActor () -> Void

    init(id: String, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.action = action
    }

    @MainActor
    func callAsFunction() {
        action()
    }

    /// 클로저는 비교할 수 없으므로 **게시자 id로만** 같음을 판단한다.
    static func == (lhs: SceneRefreshAction, rhs: SceneRefreshAction) -> Bool {
        lhs.id == rhs.id
    }
}

extension FocusedValues {

    var sceneRefresh: SceneRefreshAction? {
        get { self[SceneRefreshKey.self] }
        set { self[SceneRefreshKey.self] = newValue }
    }

    private struct SceneRefreshKey: FocusedValueKey {
        typealias Value = SceneRefreshAction
    }
}
