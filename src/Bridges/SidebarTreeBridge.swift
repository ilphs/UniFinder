import AppKit
import SwiftUI

/// 원시 `keyDown`을 Coordinator로 넘기는 `NSOutlineView` 서브클래스 (architect B4).
final class KeyRoutingOutlineView: NSOutlineView {

    var keyHandler: ((NSEvent) -> Bool)?
    /// 우클릭 지점의 행(항목 없으면 -1)에 맞는 컨텍스트 메뉴 (M2 T7).
    var menuProvider: ((Int) -> NSMenu?)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    /// 우클릭한 노드를 먼저 선택한 뒤 메뉴를 연다.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked >= 0, selectedRow != clicked, item(atRow: clicked) is TreeNode {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return menuProvider?(clicked)
    }
}

/// 좌측 pane — 폴더 트리 (설계 결정 #1: AppKit `NSOutlineView` 브릿지).
///
/// 폴더만 표시하고, 노드 확장 시점에 1-depth만 로드한다(설계서 §2.2).
/// 방향키·확장/축소는 `NSOutlineView` 기본 동작 + Coordinator가 소유하고,
/// `Tab` 순환만 T7(FocusBroker)에 위임한다.
struct SidebarTreeBridge: NSViewRepresentable {

    let model: TreeModel
    /// `reloadData` 필요 여부 판단용 (TreeModel.revision)
    let revision: Int
    let focusBroker: FocusBroker
    /// 붙여넣기 메뉴 활성 조건 (UI설계 §6).
    var canPaste: Bool = false
    /// 인라인 이름 변경 요청 (M2 T5). 목록과 같은 토큰 경로를 쓴다.
    var renameRequest: AppModel.RenameRequest?

    /// 파일 조작 진행 중이면 드롭을 받지 않는다 (m3-impl T3/B12).
    var isOperationInProgress: Bool = false

    /// 드롭 실행 — 목록 브릿지와 **같은** `AppModel.drop(_:into:operation:)`으로 연결한다(B9).
    var onDrop: ([URL], URL, FileOperationKind) -> Void = { _, _, _ in }

    var onSelect: (URL) -> Void
    var onRefresh: () -> Void

    // M2 — 트리 노드 컨텍스트 메뉴 (UI설계 §6)
    var onCopy: (URL) -> Void = { _ in }
    var onPaste: (URL) -> Void = { _ in }
    var onDelete: (URL) -> Void = { _ in }
    var onNewFolder: (URL) -> Void = { _ in }
    var onBeginRename: (URL) -> Void = { _ in }
    var onValidateRename: (URL, String) -> String? = { _, _ in nil }
    var onCommitRename: (URL, String) -> Void = { _, _ in }
    var onRenamingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = KeyRoutingOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.autosaveExpandedItems = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.focusRingType = .none
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.keyHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.handleKeyDown(event) ?? false
        }
        outlineView.menuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.makeContextMenu(forRow: row)
        }

        // M3 T3 — 트리 노드도 드래그 소스이자 드롭 대상이다(목록→트리 / 트리→트리 / Finder→트리).
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .regular

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.outlineView = outlineView
        focusBroker.register(treeView: outlineView)

        outlineView.reloadData()
        for section in model.sections {
            outlineView.expandItem(section)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let outlineView = scrollView.documentView as? KeyRoutingOutlineView else { return }
        context.coordinator.parent = self

        if context.coordinator.appliedRevision != revision {
            context.coordinator.appliedRevision = revision
            outlineView.reloadData()
            for section in model.sections {
                outlineView.expandItem(section)
            }
        }

        // reveal 체인 소비: 경로를 따라 순차 확장 후 마지막 노드 선택
        if let chain = model.consumePendingReveal() {
            context.coordinator.applyReveal(chain, in: outlineView)
        }

        // 인라인 이름 변경 요청 소비 (1회성). 트리에 없는 경로면 조용히 무시된다.
        if let request = renameRequest, context.coordinator.appliedRenameToken != request.token {
            context.coordinator.appliedRenameToken = request.token
            let coordinator = context.coordinator
            Task { @MainActor in
                coordinator.beginRename(at: request.url)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

        var parent: SidebarTreeBridge
        weak var outlineView: KeyRoutingOutlineView?
        var appliedRevision: Int = -1
        var appliedRenameToken: Int = -1

        /// 프로그램에 의한 선택 변경이 다시 내비게이션을 유발하지 않도록 하는 가드.
        private var isApplyingReveal = false

        /// 지금 드래그 중인 노드들의 경로 키 (M3 T3 — 자기 자신 위 드롭 방지).
        private var draggedURLKeys: Set<String> = []

        /// `validateDrop`이 확정해 사용자에게 배지로 보여준 판정 (M3 리뷰 blocker 1).
        private(set) var dropDecision = DragDropPolicy.DropDecision()

        /// 컨텍스트 메뉴를 연 노드. 메뉴 액션이 "우클릭한 대상"을 정확히 쓰게 한다
        /// (선택이 그 사이 바뀌어도 대상이 흔들리지 않도록 — m2-impl T0 "호출 시점 스냅샷").
        private var contextNode: TreeNode?

        private let folderIcon: NSImage = {
            // NSWorkspace가 돌려주는 공유 인스턴스를 직접 변형하지 않도록 사본을 만든다.
            let source = NSWorkspace.shared.icon(for: .folder)
            let image = (source.copy() as? NSImage) ?? source
            image.size = NSSize(width: 16, height: 16)
            return image
        }()

        init(_ parent: SidebarTreeBridge) {
            self.parent = parent
            super.init()
        }

        // MARK: DataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? TreeNode else {
                return parent.model.sections.count
            }
            switch node.kind {
            case .section:
                return node.children?.count ?? 0
            case .folder:
                return node.displayChildren.count
            case .placeholder:
                return 0
            }
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? TreeNode else {
                return parent.model.sections[index]
            }
            switch node.kind {
            case .section:
                return (node.children ?? [])[index]
            case .folder:
                return node.displayChildren[index]
            case .placeholder:
                return node
            }
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? TreeNode else { return false }
            switch node.kind {
            case .section:
                return !(node.children ?? []).isEmpty
            case .folder:
                // 자식을 아직 모르면 확장 가능으로 간주하고, 확장 시점에 1-depth를 로드한다.
                guard let children = node.children else { return node.isAccessible }
                return !children.isEmpty
            case .placeholder:
                return false
            }
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? TreeNode)?.kind == .section
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? TreeNode)?.isSelectable ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? TreeNode else { return nil }

            switch node.kind {
            case .section:
                let cell = outlineView.makeView(withIdentifier: TreeSectionCellView.identifier, owner: nil) as? TreeSectionCellView
                    ?? TreeSectionCellView(frame: .zero)
                cell.identifier = TreeSectionCellView.identifier
                cell.configure(title: node.name)
                return cell

            case .folder:
                let cell = outlineView.makeView(withIdentifier: TreeNodeCellView.identifier, owner: nil) as? TreeNodeCellView
                    ?? TreeNodeCellView(frame: .zero)
                cell.identifier = TreeNodeCellView.identifier
                cell.configure(node: node, folderIcon: folderIcon)
                wireRenameCallbacks(on: cell)
                return cell

            case .placeholder:
                let cell = outlineView.makeView(withIdentifier: TreePlaceholderCellView.identifier, owner: nil) as? TreePlaceholderCellView
                    ?? TreePlaceholderCellView(frame: .zero)
                cell.identifier = TreePlaceholderCellView.identifier
                return cell
            }
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
            // 자식 로드도 DirectoryLoader(actor) 경유 — UI 스레드 블로킹 방지 (구현계획서 §6)
            parent.model.expandInBackground(node)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
            parent.model.setCollapsed(node)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingReveal else { return }
            guard let outlineView else { return }
            let row = outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? TreeNode, node.kind == .folder else { return }
            parent.onSelect(node.url)
        }

        // MARK: 드래그앤드롭 (M3 T3 / B9·B12·B13)

        /// 폴더 노드만 드래그할 수 있다(섹션 헤더·placeholder 제외).
        /// 보호 대상(홈/볼륨 루트)의 이동 거부는 서비스 가드가 담당한다 — 여기서 막으면
        /// "홈 폴더를 다른 곳에 **복사**"까지 못 하게 된다(B10 — UI 거부는 보조 수단).
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let node = item as? TreeNode, node.kind == .folder else { return nil }
            return node.url as NSURL
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            draggedURLKeys = Set(draggedItems.compactMap { ($0 as? TreeNode).map { PathKey.key($0.url) } })
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            draggedURLKeys = []
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: any NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            // 판정을 내지 못한 검증은 이유를 가리지 않고 캐시를 남기지 않는다(목록 브릿지와 동일 — 선택 6).
            dropDecision.clear()

            // B12 — 조작 진행 중에는 드롭 자체를 받지 않는다.
            guard !parent.isOperationInProgress else { return [] }
            guard let node = dropTargetNode(item) else { return [] }
            let urls = DragDropPolicy.fileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty, DragDropPolicy.canAcceptDrop(urls: urls, into: node.url) else { return [] }
            guard !draggedURLKeys.contains(PathKey.key(node.url)) else { return [] }
            guard let kind = dropKind(urls: urls, destination: node.url, sourceMask: info.draggingSourceOperationMask)
            else { return [] }

            // 사용자에게 배지로 보여준 판정을 그대로 `acceptDrop`까지 나른다(blocker 1 — (a) 방향).
            dropDecision.record(kind, destination: node.url)
            // 노드 "위"에만 놓을 수 있다(자식 사이 삽입은 의미가 없다 — 파일시스템에 순서가 없다).
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return DragDropPolicy.draggingOperation(for: kind)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: any NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            // 드롭 1건이 끝나면 어떤 경로로 빠져나가든 판정 캐시를 비운다(선택 6).
            defer { dropDecision.clear() }

            guard !parent.isOperationInProgress else { return false }
            guard let node = dropTargetNode(item) else { return false }
            let urls = DragDropPolicy.fileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty, DragDropPolicy.canAcceptDrop(urls: urls, into: node.url) else { return false }

            // 목록 브릿지와 **같은** 규칙(권장 1): 배지로 확인시킨 판정은 현재 마스크가 그것을 여전히
            // 허용할 때만 이기고, 마스크가 한쪽으로 제한하면 마스크가 이긴다.
            // `NSEvent.modifierFlags`는 어느 경로에서도 읽지 않는다(blocker 1).
            guard let kind = dropKind(
                urls: urls,
                destination: node.url,
                sourceMask: info.draggingSourceOperationMask,
                recalled: dropDecision.recall(destination: node.url)
            ) else { return false }

            // B9 — 목록과 동일하게 `AppModel.drop`을 경유한다.
            parent.onDrop(urls, node.url, kind)
            return true
        }

        private func dropTargetNode(_ item: Any?) -> TreeNode? {
            guard let node = item as? TreeNode, node.kind == .folder else { return nil }
            return node
        }

        /// 목록 브릿지의 `dropKind`와 **같은 규칙**을 공유한다(`DragDropPolicy` 단일 지점).
        /// 목록→트리와 트리→트리가 다르게 동작하면 안 된다 — 캐시 합의 규칙(`settle`)까지 포함해서다.
        func dropKind(
            urls: [URL],
            destination: URL,
            sourceMask: NSDragOperation,
            recalled: FileOperationKind? = nil
        ) -> FileOperationKind? {
            let sameVolume = DragDropPolicy.isSameVolume(urls: urls, destination: destination)
            return DragDropPolicy.settle(recalled: recalled, sourceMask: sourceMask, isSameVolume: sameVolume)
        }

        // MARK: reveal

        /// 경로 체인을 순차 확장하고 마지막 노드를 선택한다 (설계서 §2.2 동기화).
        func applyReveal(_ chain: [TreeNode], in outlineView: NSOutlineView) {
            guard let target = chain.last else { return }
            isApplyingReveal = true
            defer { isApplyingReveal = false }

            outlineView.reloadData()
            for node in chain.dropLast() {
                outlineView.expandItem(node)
            }

            let row = outlineView.row(forItem: target)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }

        // MARK: 인라인 이름 변경 (M2 T5)

        /// 목록 셀과 동일한 규칙 — 커밋 대상은 편집 시작 시점의 URL이다 (architect B7).
        private func wireRenameCallbacks(on cell: TreeNodeCellView) {
            cell.nameEditor.validate = { [weak self] url, name in
                self?.parent.onValidateRename(url, name)
            }
            cell.nameEditor.onCommit = { [weak self] url, name in
                self?.parent.onCommitRename(url, name)
            }
            cell.nameEditor.onEnd = { [weak self] _ in
                self?.parent.onRenamingChanged(false)
            }
        }

        func beginRename(at url: URL) {
            guard let outlineView else { return }
            guard let node = parent.model.node(for: url), !parent.model.isProtectedNode(node) else { return }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }

            outlineView.scrollRowToVisible(row)
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? TreeNodeCellView
            else { return }

            parent.onRenamingChanged(true)
            cell.beginRename()
        }

        /// 현재 선택된 폴더 노드 (섹션/placeholder는 제외).
        private func selectedNode() -> TreeNode? {
            guard let outlineView, outlineView.selectedRow >= 0 else { return nil }
            guard let node = outlineView.item(atRow: outlineView.selectedRow) as? TreeNode, node.kind == .folder
            else { return nil }
            return node
        }

        // MARK: 컨텍스트 메뉴 (M2 T7 / UI설계 §6)

        func makeContextMenu(forRow row: Int) -> NSMenu? {
            guard let outlineView, row >= 0,
                  let node = outlineView.item(atRow: row) as? TreeNode,
                  node.kind == .folder
            else { return nil }

            // 위험 대상 가드 (m2-impl T0): 즐겨찾기 항목·볼륨 루트·홈 루트는 삭제/이름변경 비활성
            let isProtected = parent.model.isProtectedNode(node)
            contextNode = node

            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(makeItem("열기", #selector(menuOpen), key: "", modifiers: []))
            menu.addItem(.separator())
            menu.addItem(makeItem("복사", #selector(menuCopy), key: "c", modifiers: .command))
            menu.addItem(makeItem("붙여넣기", #selector(menuPaste), key: "v", modifiers: .command, enabled: parent.canPaste))
            menu.addItem(.separator())
            menu.addItem(makeItem("이름 변경", #selector(menuRename), key: String(KeyScalar.f2), modifiers: [], enabled: !isProtected))
            menu.addItem(makeItem("휴지통으로 이동", #selector(menuDelete), key: "\u{8}", modifiers: .command, enabled: !isProtected))
            menu.addItem(.separator())
            menu.addItem(makeItem("새 폴더", #selector(menuNewFolder), key: "n", modifiers: [.command, .shift]))
            return menu
        }

        private func makeItem(
            _ title: String,
            _ action: Selector,
            key: String,
            modifiers: NSEvent.ModifierFlags,
            enabled: Bool = true
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.isEnabled = enabled
            return item
        }

        @objc private func menuOpen() {
            guard let node = contextNode else { return }
            parent.onSelect(node.url)
        }

        @objc private func menuCopy() {
            guard let node = contextNode else { return }
            parent.onCopy(node.url)
        }

        @objc private func menuPaste() {
            guard let node = contextNode else { return }
            parent.onPaste(node.url)
        }

        @objc private func menuRename() {
            guard let node = contextNode else { return }
            parent.onBeginRename(node.url)
        }

        @objc private func menuDelete() {
            guard let node = contextNode else { return }
            parent.onDelete(node.url)
        }

        @objc private func menuNewFolder() {
            guard let node = contextNode else { return }
            parent.onNewFolder(node.url)
        }

        // MARK: 키보드 (architect B4)

        func handleKeyDown(_ event: NSEvent) -> Bool {
            // `.function`/`.numericPad`는 AppKit이 기능키에 자동으로 붙인다 (m2-impl T2)
            let modifiers = KeyScalar.userModifiers(of: event)
            guard let scalar = (event.charactersIgnoringModifiers ?? "").unicodeScalars.first else { return false }

            if scalar == KeyScalar.tab && modifiers.isEmpty {
                parent.focusBroker.cycleFocus(from: .tree)
                return true
            }

            if modifiers.contains(.command) {
                // m2-impl T2/B2 — 휴지통 이동은 `Cmd+Backspace`
                guard scalar == KeyScalar.backspace, let node = selectedNode() else { return false }
                guard !parent.model.isProtectedNode(node) else { return true }
                parent.onDelete(node.url)
                return true
            }

            guard modifiers.isEmpty else { return false }

            switch scalar {
            case KeyScalar.carriageReturn, KeyScalar.enter, KeyScalar.newline:
                // 선택된 폴더를 우측 pane으로 연다
                if let node = selectedNode() {
                    parent.onSelect(node.url)
                }
                return true

            case KeyScalar.f5:
                parent.onRefresh()
                return true

            case KeyScalar.f2:
                if let node = selectedNode(), !parent.model.isProtectedNode(node) {
                    parent.onBeginRename(node.url)
                }
                return true

            case KeyScalar.forwardDelete:
                // m2-impl T2/B2 — `fn+Delete`(⌦) = 휴지통 이동
                if let node = selectedNode(), !parent.model.isProtectedNode(node) {
                    parent.onDelete(node.url)
                }
                return true

            default:
                return false
            }
        }
    }
}
