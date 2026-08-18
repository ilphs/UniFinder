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
    /// 볼륨 아이콘 캐시 무효화 판단용 (TreeModel.sectionsRevision — 2026-08-18 C단계).
    /// `revision`은 노드 확장마다 올라가므로 여기에 캐시를 묶으면 스크롤 중 캐시가 통째로 버려진다.
    var sectionsRevision: Int = 0
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

    // 2026-08-18 — 즐겨찾기 등록/해제 (트리 컨텍스트 메뉴 진입점).
    var isFavorite: (URL) -> Bool = { _ in false }
    var onToggleFavorite: (URL) -> Void = { _ in }

    /// "Open in New Window" (다중 창 T7). 트리 노드는 전부 폴더라 대상 판정이 필요 없다.
    var onOpenInNewWindow: (URL) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = KeyRoutingOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        // 2026-08-18 사이드바 확대 — `.default`는 시스템이 정한 **고정** 행 높이라 키운 헤더가
        // 위아래로 잘리고, 폴더 행도 우측 목록(22pt)과 다른 리듬이 된다. `.custom`으로 두어야
        // 아래 `heightOfRowByItem` 델리게이트가 반영된다
        // (`.custom` 이외의 값에서는 AppKit이 델리게이트 높이를 무시한다).
        outlineView.rowSizeStyle = .custom
        // 그룹 행을 쓰지 않으므로(`isGroupItem` 주석 참조) 부유 헤더 옵션도 의미가 없지만,
        // 기본값이 바뀌더라도 헤더가 스크롤 중 떠 있지 않도록 명시해 둔다.
        outlineView.floatsGroupRows = false
        // 폴더 아이콘이 우측 목록과 같은 16pt이므로 들여쓰기도 기존 값을 유지한다.
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

        // 볼륨 구성/이름이 바뀐 경우에만 아이콘 캐시를 버린다 (마운트·언마운트·볼륨 rename은
        // 전부 `TreeModel.rebuildSections()`를 거치므로 이 카운터 하나로 세 경우가 모두 잡힌다).
        context.coordinator.invalidateVolumeIconsIfNeeded(sectionsRevision: sectionsRevision)

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
        //
        // **토큰은 편집에 실제로 진입했을 때만 소비한다** (M2 백로그 — 목록 브릿지와 같은 규칙).
        // 예전에는 `beginRename` 호출 **전에** 소비해서, 노드가 아직 트리에 없거나 셀이 윈도우에
        // 붙기 전이면(새 폴더 생성 직후) 재시도 기회 없이 요청이 사라졌다.
        if let request = renameRequest, context.coordinator.scheduleRenameIfNeeded(request) {
            let coordinator = context.coordinator
            Task { @MainActor in
                coordinator.applyRenameRequest(request)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

        var parent: SidebarTreeBridge
        weak var outlineView: KeyRoutingOutlineView?
        var appliedRevision: Int = -1
        /// **편집에 실제로 진입한** rename 토큰. 진입 실패는 소비로 치지 않는다(재시도 대상 — M2 백로그).
        private(set) var appliedRenameToken: Int = -1
        /// 다음 런루프에 이미 예약된 토큰 — 같은 요청이 여러 번 스케줄되지 않게 한다.
        private(set) var scheduledRenameToken: Int = -1
        /// 같은 토큰의 재시도 횟수. 트리에 영영 나타나지 않는 대상(파일 rename 요청 등)에 대한
        /// 무한 재시도를 막는 상한이다.
        private var renameAttemptCount = 0
        static let maxRenameAttempts = 50

        /// 프로그램에 의한 선택 변경이 다시 내비게이션을 유발하지 않도록 하는 가드.
        private var isApplyingReveal = false

        /// 지금 드래그 중인 노드들의 경로 키 (M3 T3 — 자기 자신 위 드롭 방지).
        private var draggedURLKeys: Set<String> = []

        /// `validateDrop`이 확정해 사용자에게 배지로 보여준 판정 (M3 리뷰 blocker 1).
        private(set) var dropDecision = DragDropPolicy.DropDecision()

        /// 컨텍스트 메뉴를 연 노드. 메뉴 액션이 "우클릭한 대상"을 정확히 쓰게 한다
        /// (선택이 그 사이 바뀌어도 대상이 흔들리지 않도록 — m2-impl T0 "호출 시점 스냅샷").
        private var contextNode: TreeNode?

        /// 볼륨 노드 전용 아이콘 캐시 (2026-08-18). 무효화는 `sectionsRevision` 변화 시에만.
        let volumeIconCache = VolumeIconCache()
        private var appliedSectionsRevision: Int = -1

        private let folderIcon: NSImage = {
            // NSWorkspace가 돌려주는 공유 인스턴스를 직접 변형하지 않도록 사본을 만든다.
            let source = NSWorkspace.shared.icon(for: .folder)
            let image = (source.copy() as? NSImage) ?? source
            // 셀 아이콘 프레임과 **같은** 크기여야 한다 — 더 작으면 `.scaleProportionallyDown`이
            // 확대를 하지 않아 프레임 안에서 아이콘만 작게 남는다(`VolumeIconCache`와 같은 규칙).
            // 숫자를 적지 않고 상수를 참조해 프레임 변경에 자동으로 따라가게 한다.
            image.size = NSSize(width: SidebarMetrics.nodeIconLength, height: SidebarMetrics.nodeIconLength)
            return image
        }()

        init(_ parent: SidebarTreeBridge) {
            self.parent = parent
            super.init()
        }

        /// 섹션 재구성이 있었으면 볼륨 아이콘 캐시를 비운다.
        func invalidateVolumeIconsIfNeeded(sectionsRevision: Int) {
            guard appliedSectionsRevision != sectionsRevision else { return }
            appliedSectionsRevision = sectionsRevision
            volumeIconCache.invalidate()
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

        /// 섹션을 **그룹 행으로 선언하지 않는다** (2026-08-18 — 헤더 확대 요청 때문에 뒤집힌 결정).
        ///
        /// `style = .sourceList`에서 `isGroupItem == true`인 행은 AppKit이 셀의 텍스트 폰트와
        /// 심볼 크기를 **표준 사이드바 헤더 크기로 강제**한다. 우리가 셀에 지정한 값은 화면에 반영되지
        /// 않는다. 다음을 모두 시도했고 전부 무력화되는 것을 실행 화면에서 확인했다:
        /// - `setup()`에서 폰트 지정 / `viewWillDraw()`에서 그리기 직전 재지정
        /// - `NSTextField.font` 세터 차단 / `NSTextFieldCell.font` 세터 차단
        /// - `NSImageView.image`·`symbolConfiguration` 세터 차단
        ///
        /// **판별 방법**(회귀 시 같은 방법으로 재확인할 것): 헤더 폰트를 24pt까지 키워도 글자 크기가
        /// 전혀 변하지 않는 반면, `heightOfRowByItem`이 정하는 **행 높이는 정상 반영**된다.
        /// 즉 "바이너리가 낡았나?"가 아니라 AppKit이 폰트만 덮어쓰는 것이다.
        /// 프로퍼티를 다시 읽으면 우리 값이 그대로라 **단위 테스트로는 잡히지 않는다** — 화면에서만 보인다.
        ///
        /// 그룹 행을 포기하면서 잃는 것/얻는 것:
        /// - 잃음: 그룹 전용 배경, 헤더 위 자동 여백, hover 시 "Show/Hide" 버튼
        /// - 얻음: 헤더 폰트/심볼 크기의 **완전한 통제**(사용자 요청의 핵심), 디스클로저 삼각형으로
        ///   섹션 접기/펼치기 유지(Win10 탐색기의 섹션도 같은 방식이라 지향점과도 맞는다)
        /// - 선택 불가는 그룹 행이 아니라 `shouldSelectItem`이 보장하므로 영향 없다.
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            false
        }

        /// 행 높이 (2026-08-18 사이드바 확대 — 헤더 26pt / 폴더 행 22pt).
        ///
        /// 헤더는 키운 심볼·텍스트를 담아야 하고, 폴더 행은 **우측 목록과 같은 22pt**여야 하므로
        /// 종류별로 값이 다르다. 값 자체는 셀 레이아웃과 어긋나지 않도록 `SidebarMetrics`가 단독으로
        /// 소유하고(폴더 행은 다시 `FileListMetrics`를 참조한다) 여기서는 분기만 한다.
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            rowHeight(for: item)
        }

        /// 테스트가 델리게이트 경유 없이 직접 검증할 수 있게 분리해 둔다.
        func rowHeight(for item: Any) -> CGFloat {
            guard let node = item as? TreeNode else { return SidebarMetrics.nodeRowHeight }
            // placeholder("Loading…")는 폴더 행 자리에 뜨므로 폴더 행과 같은 높이를 쓴다.
            return node.kind == .section ? SidebarMetrics.sectionRowHeight : SidebarMetrics.nodeRowHeight
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
                // 심볼은 **섹션 이름 문자열이 아니라** `sectionKind`에서 온다 (헤더 문구가 바뀌어도 안전).
                cell.configure(title: node.name, symbolName: node.sectionKind?.symbolName)
                return cell

            case .folder:
                let cell = outlineView.makeView(withIdentifier: TreeNodeCellView.identifier, owner: nil) as? TreeNodeCellView
                    ?? TreeNodeCellView(frame: .zero)
                cell.identifier = TreeNodeCellView.identifier
                // 볼륨 루트만 실제 디스크 아이콘을 쓴다. 조회 실패 시 공용 폴더 아이콘으로 되돌린다.
                let icon = node.isVolumeRoot ? (volumeIconCache.icon(for: node.url) ?? folderIcon) : folderIcon
                cell.configure(node: node, folderIcon: icon)
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

        /// 이 요청을 다음 런루프에 예약해야 하는지. 예약하기로 했으면 그 사실을 기록한다.
        func scheduleRenameIfNeeded(_ request: AppModel.RenameRequest) -> Bool {
            guard appliedRenameToken != request.token, scheduledRenameToken != request.token else { return false }
            scheduledRenameToken = request.token
            return true
        }

        /// 예약된 rename 요청을 실행한다. **성공했을 때만** 토큰을 소비한다 (목록 브릿지와 동일 규칙).
        /// - Returns: 편집에 진입했으면 `true`
        @discardableResult
        func applyRenameRequest(_ request: AppModel.RenameRequest) -> Bool {
            scheduledRenameToken = -1
            if beginRename(at: request.url) {
                appliedRenameToken = request.token
                renameAttemptCount = 0
                return true
            }
            // 실패 — 토큰을 남겨 다음 `updateNSView`(노드 확장/로드 완료 등)에서 다시 시도한다.
            renameAttemptCount += 1
            if renameAttemptCount >= Self.maxRenameAttempts {
                appliedRenameToken = request.token
                renameAttemptCount = 0
            }
            return false
        }

        /// - Returns: 해당 노드의 셀이 **실제로** 편집에 진입했으면 `true`.
        @discardableResult
        func beginRename(at url: URL) -> Bool {
            guard let outlineView else { return false }
            guard let node = parent.model.node(for: url), !parent.model.isProtectedNode(node) else { return false }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return false }

            outlineView.scrollRowToVisible(row)
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? TreeNodeCellView
            else { return false }

            // 목록 브릿지와 같은 순서 — 진입에 성공한 뒤에만 편집 중 상태를 세운다 (M2 백로그).
            // 먼저 세우면 편집 중이 아닌데 `AppModel.isRenaming`이 고착된다.
            guard cell.beginRename() else { return false }
            parent.onRenamingChanged(true)
            return true
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
            menu.addItem(makeItem("Open", #selector(menuOpen), key: "", modifiers: []))
            // 다중 창 T7 — Finder/Win10 탐색기와 같은 자리(Open 바로 아래).
            // 대상은 `contextNode` 스냅샷이라 메뉴가 떠 있는 사이 선택이 바뀌어도 흔들리지 않는다.
            menu.addItem(makeItem("Open in New Window", #selector(menuOpenInNewWindow), key: "", modifiers: []))
            menu.addItem(.separator())
            menu.addItem(makeItem("Copy", #selector(menuCopy), key: "c", modifiers: .command))
            menu.addItem(makeItem("Paste", #selector(menuPaste), key: "v", modifiers: .command, enabled: parent.canPaste))
            menu.addItem(.separator())
            menu.addItem(makeItem("Rename", #selector(menuRename), key: String(KeyScalar.f2), modifiers: [], enabled: !isProtected))
            menu.addItem(makeItem("Move to Trash", #selector(menuDelete), key: "\u{8}", modifiers: .command, enabled: !isProtected))
            menu.addItem(.separator())
            menu.addItem(makeItem("New Folder", #selector(menuNewFolder), key: "n", modifiers: [.command, .shift]))
            menu.addItem(.separator())

            // 즐겨찾기 토글 (2026-08-18). **위험 대상 가드와 무관하다** —
            // 즐겨찾기 해제는 파일시스템을 건드리지 않고 목록에서만 빼는 별개 개념이라,
            // `isProtected`(rename/삭제 금지)로 비활성화하면 즐겨찾기 항목을 영영 못 지운다.
            // 트리 노드는 전부 폴더(`kind == .folder` 가드)이므로 파일 비활성 조건은 필요 없다.
            menu.addItem(makeItem(
                parent.isFavorite(node.url) ? "Remove from Favorites" : "Add to Favorites",
                #selector(menuToggleFavorite),
                key: "t",
                modifiers: [.control, .command]
            ))
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

        @objc private func menuOpenInNewWindow() {
            guard let node = contextNode else { return }
            parent.onOpenInNewWindow(node.url)
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

        @objc private func menuToggleFavorite() {
            guard let node = contextNode else { return }
            parent.onToggleFavorite(node.url)
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
