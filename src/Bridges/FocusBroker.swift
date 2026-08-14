import AppKit

/// 트리 ↔ 목록 ↔ 주소창 사이의 first responder 정책과 `Tab` 순환을 한 곳에서 관리한다 (T7).
///
/// 브릿지(T3/T4)는 원시 `keyDown`을 직접 소유하고(architect B4), `Tab`을 만나면
/// 여기로 위임만 한다 — 브릿지 내부 키 처리를 T7이 다시 쓰지 않기 위한 경계.
@MainActor
final class FocusBroker {

    enum Target {
        case list
        case tree
        case address
    }

    private(set) weak var listView: NSView?
    private(set) weak var treeView: NSView?

    /// 주소창이 편집 모드인지 — 편집 중에는 목록 단축키를 비활성화한다.
    var isAddressEditing = false

    /// 인라인 이름 변경 중인지 (m2-impl T5 / architect B7).
    ///
    /// 편집 중에는 field editor가 first responder라 `currentFocus`가 `nil`이 된다.
    /// `isAddressEditing`과 대칭되는 이 플래그가 있어야 refresh/reveal/포커스 강제 이동과
    /// 앱 메뉴 단축키(`Cmd+C/X/V`)를 억제해 텍스트 필드의 기본 편집을 방해하지 않는다.
    var isRenaming = false

    /// 시트/알림을 붙일 윈도우 (충돌 시트·확인 알림 공용).
    var window: NSWindow? {
        listView?.window ?? treeView?.window
    }

    /// 주소창 편집을 시작/종료시키는 훅 (MainWindow가 연결).
    var beginAddressEditing: (() -> Void)?

    func register(listView: NSView) {
        self.listView = listView
        wireKeyViewLoop()
    }

    func register(treeView: NSView) {
        self.treeView = treeView
        wireKeyViewLoop()
    }

    private func wireKeyViewLoop() {
        guard let listView, let treeView else { return }
        listView.nextKeyView = treeView
        treeView.nextKeyView = listView
    }

    /// UI설계 §9 — `Tab` 순환: 목록 → 트리 → 목록
    func cycleFocus(from current: Target) {
        switch current {
        case .list: focus(.tree)
        case .tree: focus(.list)
        case .address: focus(.list)
        }
    }

    func focus(_ target: Target) {
        switch target {
        case .list:
            makeFirstResponder(listView)
        case .tree:
            makeFirstResponder(treeView)
        case .address:
            beginAddressEditing?()
        }
    }

    /// 앱 시작·폴더 이동 후 포커스는 목록으로 (UI설계 §9).
    ///
    /// 단, 트리에서 방향키로 이동 중일 때는 호출하면 안 된다 — first responder가 매 이동마다
    /// 목록으로 끌려가 트리 키보드 탐색 자체가 불가능해진다(`AppModel.NavigationSource` 참조).
    func focusListSoon() {
        Task { @MainActor in
            self.focus(.list)
        }
    }

    /// 현재 first responder가 어느 pane인지. 둘 다 아니면 `nil`.
    ///
    /// `NSTableView`/`NSOutlineView`는 자기 자신이 first responder가 되므로 뷰 동일성으로 판별한다.
    var currentFocus: Target? {
        guard let window = listView?.window ?? treeView?.window else { return nil }
        let responder = window.firstResponder
        if let listView, responder === listView { return .list }
        if let treeView, responder === treeView { return .tree }
        return nil
    }

    /// 트리가 이미 키보드 포커스를 갖고 있는지 — 트리발 이동에서 포커스 탈취를 막는 판단 근거.
    var isTreeFocused: Bool { currentFocus == .tree }

    private func makeFirstResponder(_ view: NSView?) {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}
