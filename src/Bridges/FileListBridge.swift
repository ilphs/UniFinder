import AppKit
import QuickLookUI
import SwiftUI

/// 원시 `keyDown`을 Coordinator로 넘기는 `NSTableView` 서브클래스.
/// architect B4 — 목록 내부의 방향키·Enter·타입-어헤드는 이 브릿지가 소유한다.
///
/// **QuickLook 패널 제어도 여기가 소유한다** (m3-impl T4/B15): 이 앱은 SwiftUI 씬(`Window`)으로만
/// 창을 만들어 `NSWindowController`가 없고 `Coordinator`는 `NSObject`일 뿐 responder chain에 없다.
/// `QLPreviewPanel`은 responder chain에서 `acceptsPreviewPanelControl(_:)`을 찾으므로,
/// **실제 first responder인 이 테이블뷰**가 그 3개를 구현하고 datasource/delegate만 Coordinator에 위임한다.
final class KeyRoutingTableView: NSTableView {

    var keyHandler: ((NSEvent) -> Bool)?
    var focusChanged: ((Bool) -> Void)?
    /// 우클릭 지점의 행(항목 없으면 -1)에 맞는 컨텍스트 메뉴를 만들어 준다 (M2 T7).
    var menuProvider: ((Int) -> NSMenu?)?

    /// QuickLook 패널의 datasource/delegate를 맡을 객체 (Coordinator).
    weak var quickLookController: (NSObject & QLPreviewPanelDataSource & QLPreviewPanelDelegate)?

    override var acceptsFirstResponder: Bool { true }

    // MARK: - QLPreviewPanelController (B15)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookController != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookController
        panel.delegate = quickLookController
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged?(false) }
        return result
    }

    /// 우클릭한 행이 선택에 없으면 그 행만 선택한 뒤 메뉴를 연다 (Finder/탐색기 공통 동작).
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked >= 0, !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return menuProvider?(clicked)
    }
}

/// 우측 pane — 4컬럼 상세 목록 (설계 결정 #1: AppKit `NSTableView` 브릿지).
///
/// 키보드 소유권(architect B4): 방향키/PageUp·Down/Home·End/`Enter`/타입-어헤드 문자는
/// 이 브릿지의 Coordinator가 직접 처리하고, 상위(T7)에는 `onOpen`/`onNavigateUp`/
/// `onTypeAhead` 등 의미 단위 콜백만 노출한다. M2도 같은 규칙을 따라
/// `onCopy`/`onCut`/`onPaste`/`onDelete`/`onBeginRename`/`onCommitRename`을 추가한다.
struct FileListBridge: NSViewRepresentable {

    let items: [FileItem]
    /// `reloadData` 필요 여부 판단용 (DirectoryModel.revision)
    let revision: Int
    /// 외부 변경(FSEvents) 반영용 카운터 (m3-impl T0/B5).
    /// `revision`과 달리 **스크롤·선택을 건드리지 않는** 갱신을 요구한다.
    var contentsRevision: Int = 0
    let sortDescriptor: FileSortDescriptor
    @Binding var selection: Set<URL>

    // M2 입력. 전부 기본값을 둬서 브릿지 단위 테스트가 필요한 부분만 주입할 수 있게 한다
    // (M1의 `onTypeAhead` 등과 달리 개수가 많아 호출부가 비대해지는 것을 막는 목적도 있다).

    /// 잘라내기 대기 항목 (UI설계 §4.2 — 50% 불투명).
    var cutURLs: Set<URL> = []
    /// **이 값이 없으면 클립보드 상태가 바뀌어도 화면이 갱신되지 않는다** (architect B6).
    /// `updateNSView`는 `revision`/`items.count` 변화에만 `reloadData`하기 때문.
    var clipboardRevision: Int = 0
    /// 붙여넣기 메뉴 활성 조건 (UI설계 §6).
    var canPaste: Bool = false
    /// 인라인 이름 변경 요청 (F2 / 컨텍스트 메뉴 / 새 폴더 생성 직후 — M2 T5·T6).
    var renameRequest: AppModel.RenameRequest?

    /// 현재 표시 중인 폴더 — 빈 영역 드롭의 대상 (M3 T3).
    var currentDirectory: URL?
    /// 파일 조작이 진행 중인지. 진행 중이면 드롭을 **아예 받지 않는다**(m3-impl B12) —
    /// `acceptDrop`에서 true를 돌려주면 "드롭 성공 후 아무 일도 없음"으로 보인다.
    var isOperationInProgress: Bool = false
    /// 텍스트 편집(주소창/인라인 rename) 중인지 — QuickLook 패널을 닫는 신호 (m3-impl B16).
    var isTextEditing: Bool = false

    let focusBroker: FocusBroker
    let settings: AppSettings

    var onOpen: ([FileItem]) -> Void
    var onNavigateUp: () -> Void
    var onSortChange: (SortKey) -> Void
    var onRefresh: () -> Void
    var onTypeAhead: (String) -> Void

    /// Space 키 — QuickLook 토글 (M3 T4/B14).
    /// **분기 구조는 M1 그대로다**: 타입-어헤드 진행 중이면 검색 문자열, 아니면 이 콜백.
    var onQuickLook: () -> Void = {}

    /// 드롭 실행 — 반드시 `AppModel.drop(_:into:operation:)`으로 연결한다 (m3-impl B9).
    /// 브릿지가 `FileOperations`를 직접 호출하면 `runOperation` 직렬화와
    /// `applyOperationResult` 단일 경유점을 우회하게 된다.
    var onDrop: ([URL], URL, FileOperationKind) -> Void = { _, _, _ in }

    // M2 — 의미 단위 콜백 (M1의 onOpen/onNavigateUp과 같은 패턴)

    /// 컨텍스트 메뉴에서 기준/방향을 직접 지정하는 경로 (헤더 클릭의 토글과 구분).
    var onApplySort: (FileSortDescriptor) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onCut: () -> Void = {}
    var onPaste: () -> Void = {}
    var onDelete: () -> Void = {}
    var onNewFolder: () -> Void = {}
    var onRevealInFinder: () -> Void = {}

    // 2026-08-18 — 즐겨찾기 등록/해제 (컨텍스트 메뉴 진입점). 폴더에만 의미가 있다.
    var isFavorite: (URL) -> Bool = { _ in false }
    var onToggleFavorite: (URL) -> Void = { _ in }
    var onBeginRename: (URL) -> Void = { _ in }
    /// 커밋 직전 동기 검증. 사유를 돌려주면 편집이 유지된다 (UI설계 §7.2).
    var onValidateRename: (URL, String) -> String? = { _, _ in nil }
    var onCommitRename: (URL, String) -> Void = { _, _ in }
    /// 인라인 편집 시작/종료 — `AppModel.isRenaming` 토글용.
    var onRenamingChanged: (Bool) -> Void = { _ in }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = KeyRoutingTableView()
        tableView.style = .fullWidth
        tableView.rowHeight = 22 // UI설계 §4.1
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        // UI설계 §4.1 — "이름"만 잔여 폭을 흡수하고 나머지는 고정 폭을 유지한다.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.tableViewDoubleClicked(_:))
        tableView.keyHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.handleKeyDown(event) ?? false
        }
        tableView.menuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.makeContextMenu(forRow: row)
        }

        // M3 T3 — 드래그앤드롭. 외부(Finder)와는 파일 URL로 상호 운용한다.
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular

        for column in Self.makeColumns(settings: settings) {
            tableView.addTableColumn(column)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        context.coordinator.tableView = tableView
        // B15 — 패널 제어는 테이블뷰(responder chain)가, 데이터 공급은 Coordinator가 맡는다.
        tableView.quickLookController = context.coordinator
        context.coordinator.applySortIndicator(to: tableView, descriptor: sortDescriptor)
        focusBroker.register(listView: tableView)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: tableView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? KeyRoutingTableView else { return }
        context.coordinator.parent = self

        switch context.coordinator.reloadReason(
            revision: revision,
            contentsRevision: contentsRevision,
            itemCount: items.count,
            clipboardRevision: clipboardRevision
        ) {
        case .directoryChanged:
            context.coordinator.appliedRevision = revision
            context.coordinator.appliedContentsRevision = contentsRevision
            context.coordinator.appliedClipboardRevision = clipboardRevision
            context.coordinator.updateCutKeys(cutURLs)
            context.coordinator.items = items
            tableView.reloadData()
            tableView.scrollRowToVisible(0)
            context.coordinator.applySelection(selection, to: tableView)
            // UI설계 §9 — 폴더 이동 후에는 첫 항목을 선택한다.
            // (뷰 갱신 사이클 중 상태를 바꾸지 않도록 다음 런루프로 미룬다)
            if selection.isEmpty {
                let coordinator = context.coordinator
                Task { @MainActor in
                    coordinator.selectFirstRowIfNeeded()
                }
            }

        case .contentsUpdated:
            // 외부 변경(FSEvents) 반영 — **스크롤 위치와 선택을 유지한다** (m3-impl T0/B5).
            // `reloadData()`는 스크롤 원점을 보존하므로 여기서 `scrollRowToVisible(0)`을
            // 부르지 않는 것 자체가 요구사항이고, `selectFirstRowIfNeeded()`도 호출하지 않는다
            // (사라진 항목만 해제하는 선택 규칙은 `DirectoryModel.applyExternalUpdate`가 이미 적용했다).
            context.coordinator.appliedContentsRevision = contentsRevision
            context.coordinator.appliedClipboardRevision = clipboardRevision
            context.coordinator.items = items
            context.coordinator.updateCutKeys(cutURLs)
            tableView.reloadData()
            context.coordinator.applySelection(selection, to: tableView)

        case .itemsChanged:
            context.coordinator.appliedContentsRevision = contentsRevision
            context.coordinator.appliedClipboardRevision = clipboardRevision
            context.coordinator.items = items
            context.coordinator.updateCutKeys(cutURLs)
            tableView.reloadData()

        case .clipboardChanged:
            // architect B6 — 목록 내용은 그대로고 클립보드 상태만 바뀐 경우.
            // 이 분기가 없으면 잘라내기 표시(50% 불투명)가 화면에 영영 반영되지 않는다.
            context.coordinator.appliedClipboardRevision = clipboardRevision
            context.coordinator.items = items
            context.coordinator.updateCutKeys(cutURLs)
            tableView.reloadData()
            context.coordinator.applySelection(selection, to: tableView)

        case .none:
            break
        }

        // B16 — 편집이 시작되면 QuickLook 패널을 닫는다(패널이 key window를 붙들어 키 입력을 가로챈다).
        if isTextEditing {
            context.coordinator.closeQuickLookPanel()
        }

        if context.coordinator.appliedSort != sortDescriptor {
            context.coordinator.appliedSort = sortDescriptor
            context.coordinator.applySortIndicator(to: tableView, descriptor: sortDescriptor)
        }

        if !context.coordinator.isSyncingSelection {
            context.coordinator.applySelection(selection, to: tableView)
        }

        // 인라인 이름 변경 요청 소비 (1회성). 뷰 갱신 사이클 밖에서 시작한다.
        //
        // **토큰은 편집에 실제로 진입했을 때만 소비한다** (M2 리뷰 major).
        // 새 폴더 생성 직후에는 `reload(selecting:)`이 items를 비우고 비동기 로드를 시작하므로,
        // 이 시점의 목록에는 아직 만들어진 폴더가 없다. 먼저 소비해 버리면 진입에 실패해도
        // 재시도 기회가 사라져 "생성 후 즉시 rename 진입"(m2-impl T6)이 거의 항상 실패한다.
        // 로드가 끝나 items가 채워지면 `updateNSView`가 다시 오고, 그때 재시도해서 성공한다.
        if let request = renameRequest, context.coordinator.scheduleRenameIfNeeded(request) {
            let coordinator = context.coordinator
            Task { @MainActor in
                coordinator.applyRenameRequest(request)
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)

        // **QuickLook 패널을 반드시 닫는다** (M3 리뷰 blocker 3).
        // `QLPreviewPanel.dataSource`/`delegate`는 SDK 헤더상 `@property(assign)`이라 zeroing weak가 아니다.
        // 패널이 열린 채로 창이 닫히면 Coordinator와 `KeyRoutingTableView`는 해제되는데 패널은 화면에
        // 남아 dangling 포인터로 다음 콜백(`numberOfPreviewItems` 등)을 보내 크래시한다.
        // 닫으면 `endPreviewPanelControl`이 dataSource/delegate를 nil로 되돌려 참조가 끊긴다.
        coordinator.closeQuickLookPanel()
    }

    // MARK: - 컬럼 정의 (UI설계 §4.1)

    private static func makeColumns(settings: AppSettings) -> [NSTableColumn] {
        let specs: [(key: SortKey, width: Double, minWidth: Double, maxWidth: Double)] = [
            (.name, 240, 160, 10_000),
            (.date, 140, 120, 300),
            (.kind, 120, 80, 300),
            (.size, 90, 70, 200),
        ]

        return specs.map { spec in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.key.columnIdentifier))
            column.title = spec.key.localizedTitle
            column.width = settings.columnWidth(for: spec.key) ?? spec.width
            column.minWidth = spec.minWidth
            column.maxWidth = spec.maxWidth
            column.resizingMask = spec.key == .name ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            if spec.key == .size {
                column.headerCell.alignment = .right
            }
            return column
        }
    }

    // MARK: - Coordinator

    @MainActor
    /// QuickLook 프로토콜은 SDK에 `@MainActor` 표기가 없어 `@preconcurrency`로 받는다 —
    /// 실제 호출은 전부 메인 스레드(패널 UI)에서 온다.
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                             @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {

        var parent: FileListBridge
        weak var tableView: KeyRoutingTableView?

        var items: [FileItem] = []

        /// 컨텍스트 메뉴가 겨냥한 즐겨찾기 대상 (2026-08-18).
        /// 메뉴를 연 시점의 항목을 스냅샷해 둔다 — 트리 브릿지의 `contextNode`와 같은 규칙이다.
        private(set) var favoriteTarget: URL?

        var appliedRevision: Int = -1
        /// 마지막으로 반영한 외부 변경 카운터 (m3-impl T0/B5).
        var appliedContentsRevision: Int = 0
        var appliedClipboardRevision: Int = -1
        /// **편집에 실제로 진입한** rename 토큰. 진입 실패는 소비로 치지 않는다(재시도 대상).
        private(set) var appliedRenameToken: Int = -1
        /// 다음 런루프에 이미 예약된 토큰 — 같은 요청이 여러 번 스케줄되지 않게 한다.
        private(set) var scheduledRenameToken: Int = -1
        /// 같은 토큰의 재시도 횟수. 목록에 영영 나타나지 않는 항목(숨김 설정 등)에 대한
        /// 무한 재시도를 막는 상한이다.
        private var renameAttemptCount = 0
        static let maxRenameAttempts = 50
        var appliedSort: FileSortDescriptor?
        var isSyncingSelection = false

        /// 지금 드래그 중인 항목들의 경로 키 (M3 T3 — 자기 자신 위 드롭 판정용).
        private var draggedURLKeys: Set<String> = []

        /// `validateDrop`이 확정해 사용자에게 배지로 보여준 판정 (M3 리뷰 blocker 1).
        /// `acceptDrop`은 이 값을 재사용해 "본 것과 다른 동작"이 실행되지 않게 한다.
        private(set) var dropDecision = DragDropPolicy.DropDecision()

        /// 잘라내기 항목 판정용 경로 키 집합.
        /// URL 값 비교가 아니라 `PathKey`를 쓰는 이유는 폴더 URL의 후행 슬래시 때문이다
        /// (m2-impl T4 "URL 표기 정합 규칙").
        private(set) var cutKeys: Set<String> = []

        private let iconProvider = IconProvider.shared

        /// 타입-어헤드 버퍼와 마지막 입력 시각 (UI설계 §9 — 1초 유예)
        private var typeAheadBuffer = ""
        private var typeAheadLastInput = Date.distantPast
        private static let typeAheadTimeout: TimeInterval = 1.0

        init(_ parent: FileListBridge) {
            self.parent = parent
            self.items = parent.items
            super.init()
        }

        func updateCutKeys(_ urls: Set<URL>) {
            cutKeys = PathKey.key(urls)
        }

        /// `reloadData`가 필요한 이유 (architect B6).
        ///
        /// **클립보드 전용 분기가 이 판단에 포함되어야 한다.** M1은 `revision`/`items.count`
        /// 변화만 봤기 때문에, 클립보드 상태만 바뀌는 잘라내기 표시(50% 불투명)가 화면에
        /// 영영 반영되지 않았다.
        enum ReloadReason: Equatable {
            /// 폴더 내용이 통째로 바뀜 — 스크롤 초기화 + 첫 항목 선택 규칙 적용
            case directoryChanged
            /// **외부 변경(FSEvents) 반영** — `reloadData`만 하고 스크롤·첫 행 선택은 건드리지 않는다
            /// (m3-impl T0/B5). `.itemsChanged`로 대체할 수 없다: 1개 추가 + 1개 삭제면
            /// `items.count`가 같아 갱신이 통째로 누락된다.
            case contentsUpdated
            /// 같은 폴더에서 항목 수만 달라짐
            case itemsChanged
            /// 목록은 그대로, 클립보드(cut 표시)만 바뀜
            case clipboardChanged
            case none
        }

        func reloadReason(
            revision: Int,
            contentsRevision: Int = 0,
            itemCount: Int,
            clipboardRevision: Int
        ) -> ReloadReason {
            Self.reloadReason(
                appliedRevision: appliedRevision,
                revision: revision,
                appliedContentsRevision: appliedContentsRevision,
                contentsRevision: contentsRevision,
                appliedItemCount: items.count,
                itemCount: itemCount,
                appliedClipboardRevision: appliedClipboardRevision,
                clipboardRevision: clipboardRevision
            )
        }

        /// 순수 판정 — 뷰 없이 단위 테스트할 수 있도록 분리한다.
        ///
        /// 우선순위: 폴더 전환 > 외부 변경 > 항목 수 변화 > 클립보드.
        /// (폴더 전환은 어차피 전체를 다시 그리므로 나머지 신호를 포함한다)
        static func reloadReason(
            appliedRevision: Int,
            revision: Int,
            appliedContentsRevision: Int = 0,
            contentsRevision: Int = 0,
            appliedItemCount: Int,
            itemCount: Int,
            appliedClipboardRevision: Int,
            clipboardRevision: Int
        ) -> ReloadReason {
            if appliedRevision != revision { return .directoryChanged }
            if appliedContentsRevision != contentsRevision { return .contentsUpdated }
            if appliedItemCount != itemCount { return .itemsChanged }
            if appliedClipboardRevision != clipboardRevision { return .clipboardChanged }
            return .none
        }

        // MARK: DataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        // MARK: Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < items.count,
                  let identifier = tableColumn?.identifier.rawValue,
                  let key = SortKey(rawValue: identifier)
            else { return nil }

            let item = items[row]

            switch key {
            case .name:
                let cell = tableView.makeView(withIdentifier: FileNameCellView.identifier, owner: nil) as? FileNameCellView
                    ?? FileNameCellView(frame: .zero)
                cell.configure(
                    with: item,
                    iconProvider: iconProvider,
                    isCut: cutKeys.contains(PathKey.key(item.url))
                )
                wireRenameCallbacks(on: cell)
                return cell

            case .date, .kind, .size:
                let cell = tableView.makeView(withIdentifier: FileTextCellView.identifier, owner: nil) as? FileTextCellView
                    ?? FileTextCellView(frame: .zero)
                let text: String
                let alignment: NSTextAlignment
                switch key {
                case .date:
                    text = Formatters.displayDate(item.modifiedAt)
                    alignment = .left
                case .kind:
                    text = item.typeDescription
                    alignment = .left
                default:
                    text = Formatters.displaySize(item.size)
                    alignment = .right
                }
                cell.configure(text: text, alignment: alignment, isHidden: item.isHidden)
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let key = SortKey(rawValue: tableColumn.identifier.rawValue) else { return }
            parent.onSortChange(key)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            isSyncingSelection = true
            defer { isSyncingSelection = false }

            let urls = tableView.selectedRowIndexes.compactMap { row -> URL? in
                guard row >= 0, row < items.count else { return nil }
                return items[row].url
            }
            parent.selection = Set(urls)
            // 열려 있는 QuickLook 패널은 선택을 따라간다 (M3 T4).
            reloadQuickLookPanelIfVisible()
        }

        func applySelection(_ selection: Set<URL>, to tableView: NSTableView) {
            let target = IndexSet(items.indices.filter { selection.contains(items[$0].url) })
            guard target != tableView.selectedRowIndexes else { return }
            isSyncingSelection = true
            tableView.selectRowIndexes(target, byExtendingSelection: false)
            isSyncingSelection = false
        }

        /// 폴더 이동 직후 첫 항목 선택 (UI설계 §9). 이미 선택이 있으면 건드리지 않는다.
        func selectFirstRowIfNeeded() {
            guard let tableView, !items.isEmpty else { return }
            guard tableView.selectedRowIndexes.isEmpty else { return }
            guard parent.selection.isEmpty else { return }
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }

        func applySortIndicator(to tableView: NSTableView, descriptor: FileSortDescriptor) {
            for column in tableView.tableColumns {
                tableView.setIndicatorImage(nil, in: column)
            }
            guard let column = tableView.tableColumns.first(where: {
                $0.identifier.rawValue == descriptor.key.columnIdentifier
            }) else { return }

            let imageName = descriptor.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
            tableView.setIndicatorImage(NSImage(named: imageName), in: column)
            tableView.highlightedTableColumn = column
        }

        @objc func columnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let key = SortKey(rawValue: column.identifier.rawValue)
            else { return }
            parent.settings.setColumnWidth(column.width, for: key)
        }

        // MARK: QuickLook (M3 T4 / B15·B16)

        /// 미리보기 대상 = 현재 선택 항목(폴더 포함 — QuickLook은 폴더 미리보기를 지원한다).
        private var previewURLs: [URL] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { row -> URL? in
                guard row >= 0, row < items.count else { return nil }
                return items[row].url
            }
        }

        /// Space 토글 (B14가 확정한 분기에서 호출된다).
        ///
        /// 선택이 없으면 패널을 **만들지도 않는다** — 공유 패널 인스턴스화는 부작용이 있으므로
        /// 필요한 순간에만 한다.
        func toggleQuickLook() {
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.orderOut(nil)
                return
            }
            guard !previewURLs.isEmpty else { return }
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        }

        /// 편집이 시작되면 패널을 닫는다 (B16).
        ///
        /// 패널이 열린 채로 rename/주소창 편집에 들어가면 패널이 key window를 유지해 키 입력을
        /// 가로챈다 — 사용자는 "글자가 안 써진다"로 겪는다.
        /// 뷰가 해제될 때도 호출된다(`dismantleNSView`) — 그때는 닫는 것만으로 끝내지 않고
        /// **패널이 우리를 가리키는 포인터까지 끊는다**: `dataSource`/`delegate`는 `assign` 속성이라
        /// 우리가 해제돼도 nil이 되지 않는다(M3 리뷰 blocker 3).
        func closeQuickLookPanel() {
            guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
            if panel.isVisible {
                panel.orderOut(nil)
            }
            if let source = panel.dataSource, source === self {
                panel.dataSource = nil
            }
            if let delegate = panel.delegate, delegate === self {
                panel.delegate = nil
            }
        }

        /// 선택이 바뀌면 열려 있는 패널의 내용도 따라간다.
        private func reloadQuickLookPanelIfVisible() {
            guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible
            else { return }
            panel.reloadData()
        }

        // MARK: QLPreviewPanelDataSource

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            previewURLs.count
        }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
            let urls = previewURLs
            guard index >= 0, index < urls.count else { return nil }
            return urls[index] as NSURL
        }

        // MARK: QLPreviewPanelDelegate

        /// 패널이 key window인 동안에도 **방향키로 목록을 이동**할 수 있게 이벤트를 되돌린다.
        /// 그 밖의 키(Space·Esc 등)는 패널 기본 동작(닫기)에 맡긴다.
        func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
            guard event.type == .keyDown, let tableView else { return false }
            guard let scalar = (event.charactersIgnoringModifiers ?? "").unicodeScalars.first,
                  scalar == KeyScalar.upArrow || scalar == KeyScalar.downArrow
            else { return false }
            tableView.keyDown(with: event)
            reloadQuickLookPanelIfVisible()
            return true
        }

        /// 패널이 열리고 닫힐 때 확대/축소 애니메이션의 출발점 — 선택된 행의 화면 좌표.
        func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
            guard let tableView, let window = tableView.window else { return .zero }
            let row = tableView.selectedRow
            guard row >= 0 else { return .zero }
            let rowRect = tableView.rect(ofRow: row)
            return window.convertToScreen(tableView.convert(rowRect, to: nil))
        }

        // MARK: 드래그앤드롭 (M3 T3 / B9·B11·B12·B13)

        /// 드래그 소스 — 행에서 시작한 드래그만 파일 URL을 파스트보드에 올린다.
        ///
        /// **B11 — 러버밴드(빈 영역 드래그 선택)와 충돌하지 않는 이유**: AppKit은 이 메서드를
        /// *행에서 시작한 드래그*에만 호출한다. 빈 영역에서 시작한 드래그는 애초에 여기 오지 않고
        /// `NSTableView` 기본 선택 동작으로 남는다. 그래서 `tableView(_:canDragRowsWith:at:)`를
        /// 따로 구현하지 않는다 — 구현하면 오히려 기본 동작을 덮어써서 회귀 위험만 커진다.
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row >= 0, row < items.count else { return nil }
            return items[row].url as NSURL
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            // 다중 항목은 겹쳐 쌓아 개수 배지가 보이게 한다(UI설계 §4.2 다중 드래그).
            session.draggingFormation = rowIndexes.count > 1 ? .stack : .default
            session.animatesToStartingPositionsOnCancelOrFail = true
            draggedURLKeys = Set(rowIndexes.compactMap { row -> String? in
                guard row >= 0, row < items.count else { return nil }
                return PathKey.key(items[row].url)
            })
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            draggedURLKeys = []
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            // 판정을 내지 못한 검증은 **어떤 이유에서든** 캐시를 남기지 않는다(M3 리뷰 선택 6).
            // "판정이 nil일 때만 지운다"는 규칙은 거부 경로가 늘어날 때마다 빠뜨리기 쉬운 함정이었다 —
            // 여기서 한 번 지우고 성공 경로에서만 다시 기록하면 그 규칙 자체가 사라진다.
            dropDecision.clear()

            // B12 — 조작이 진행 중이면 `runOperation`이 새 요청을 무시한다.
            // 여기서 받아버리면 사용자에겐 "드롭 성공 후 아무 일도 없음"으로 보인다.
            guard !parent.isOperationInProgress else { return [] }

            let urls = DragDropPolicy.fileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return [] }

            // 행 사이(`.above`)는 순서 변경이 아니므로 폴더 행 위 또는 목록 전체(현재 폴더)로 되돌린다.
            let target = dropTarget(forRow: row, dropOperation: dropOperation)
            guard let destination = target.url else { return [] }
            guard DragDropPolicy.canAcceptDrop(urls: urls, into: destination) else { return [] }
            guard let kind = dropKind(urls: urls, destination: destination, sourceMask: info.draggingSourceOperationMask)
            else { return [] }

            // 사용자에게 배지로 보여준 판정을 그대로 `acceptDrop`까지 나른다(blocker 1 — (a) 방향).
            dropDecision.record(kind, destination: destination)
            tableView.setDropRow(target.row, dropOperation: .on)
            return DragDropPolicy.draggingOperation(for: kind)
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            // 드롭 1건이 끝나면 판정 캐시는 어떤 경로로 빠져나가든 비운다(선택 6과 같은 이유).
            defer { dropDecision.clear() }

            guard !parent.isOperationInProgress else { return false }
            let urls = DragDropPolicy.fileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            guard let destination = dropTarget(forRow: row, dropOperation: dropOperation).url else { return false }
            guard DragDropPolicy.canAcceptDrop(urls: urls, into: destination) else { return false }

            // 배지로 확인시킨 판정과 드롭 확정 순간의 마스크를 **함께** 본다(권장 1):
            // 캐시는 마스크가 그 판정을 여전히 허용할 때만 이긴다. 마스크가 한쪽으로 제한하면
            // 마스크가 이긴다 — 캐시가 소스의 copy-only 제한을 덮어써 원본을 지우는 구멍을 닫는다.
            // **어느 쪽도 `NSEvent.modifierFlags`를 읽지 않는다**(blocker 1).
            guard let kind = dropKind(
                urls: urls,
                destination: destination,
                sourceMask: info.draggingSourceOperationMask,
                recalled: dropDecision.recall(destination: destination)
            ) else { return false }

            // B9 — 실행은 반드시 `AppModel.drop`(→ runOperation → applyOperationResult)을 경유한다.
            parent.onDrop(urls, destination, kind)
            return true
        }

        /// 드롭 지점 → (실제 대상 폴더, 하이라이트할 행).
        /// 폴더 행 위면 그 폴더, 그 밖(빈 영역·행 사이·파일 행)은 현재 표시 폴더다.
        private func dropTarget(
            forRow row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> (url: URL?, row: Int) {
            if dropOperation == .on, row >= 0, row < items.count, items[row].isDirectory {
                // 드래그 중인 항목 자신 위에 놓는 것은 의미가 없다(같은 폴더 드롭으로 흡수시킨다).
                if !draggedURLKeys.contains(PathKey.key(items[row].url)) {
                    return (items[row].url, row)
                }
            }
            return (parent.currentDirectory, -1)
        }

        /// 이동/복사 판정 (B13 + M3 리뷰 blocker 1 / 권장 1).
        ///
        /// 입력은 **드래그 세션이 들고 있는 오퍼레이션 마스크**와 `validateDrop`이 배지로 보여준
        /// 판정(`recalled`)뿐이다 — 전역 `NSEvent.modifierFlags`를 읽으면 배지와 실제 동작이
        /// 어긋나고(수식키를 버튼보다 먼저 뗀 경우) 소스 앱의 제약도 무시된다.
        /// 테스트가 마스크를 직접 넣을 수 있도록 `info`가 아니라 마스크를 받는다.
        ///
        /// - Parameter recalled: `validateDrop` 경로는 `nil`(캐시 없이 마스크로만 판정),
        ///   `acceptDrop` 경로는 캐시 값을 넘긴다 — 합의 규칙은 `DragDropPolicy.settle`이 소유한다.
        func dropKind(
            urls: [URL],
            destination: URL,
            sourceMask: NSDragOperation,
            recalled: FileOperationKind? = nil
        ) -> FileOperationKind? {
            let sameVolume = DragDropPolicy.isSameVolume(urls: urls, destination: destination)
            return DragDropPolicy.settle(recalled: recalled, sourceMask: sourceMask, isSameVolume: sameVolume)
        }

        // MARK: 더블클릭

        @objc func tableViewDoubleClicked(_ sender: Any?) {
            guard let tableView else { return }
            // 헤더 더블클릭(row == -1)은 무시
            guard tableView.clickedRow >= 0, tableView.clickedRow < items.count else { return }
            parent.onOpen([items[tableView.clickedRow]])
        }

        // MARK: 인라인 이름 변경 (M2 T5)

        /// 셀이 재사용될 때마다 다시 연결한다. 커밋 대상은 셀의 현재 항목이 아니라
        /// **편집을 시작한 시점의 URL**(`InlineNameEditor.target`)이다 — architect B7.
        private func wireRenameCallbacks(on cell: FileNameCellView) {
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

        /// 예약된 rename 요청을 실행한다. **성공했을 때만** 토큰을 소비한다.
        /// - Returns: 편집에 진입했으면 `true`
        @discardableResult
        func applyRenameRequest(_ request: AppModel.RenameRequest) -> Bool {
            scheduledRenameToken = -1
            if beginRename(at: request.url) {
                appliedRenameToken = request.token
                renameAttemptCount = 0
                return true
            }
            // 실패 — 토큰을 남겨 다음 `updateNSView`(목록 로드 완료 등)에서 다시 시도한다.
            renameAttemptCount += 1
            if renameAttemptCount >= Self.maxRenameAttempts {
                appliedRenameToken = request.token
                renameAttemptCount = 0
            }
            return false
        }

        /// 지정한 항목의 이름 셀을 편집 모드로 전환한다.
        /// - Returns: 대상 행을 찾아 편집을 시작했으면 `true`. 목록에 아직 없으면 `false`.
        @discardableResult
        func beginRename(at url: URL) -> Bool {
            guard let tableView else { return false }
            let key = PathKey.key(url)
            guard let row = items.firstIndex(where: { PathKey.key($0.url) == key }) else { return false }
            guard let columnIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == SortKey.name.columnIdentifier
            }) else { return false }

            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            guard let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? FileNameCellView
            else { return false }

            // 편집 진입 시 타입-어헤드 버퍼 리셋 (m2-impl T5)
            resetTypeAhead()

            // **`onRenamingChanged(true)`는 진입에 성공한 뒤에 부른다** (M2 백로그):
            // 셀이 아직 윈도우에 붙기 전이면 `InlineNameEditor`가 조용히 실패하는데, 먼저 true를
            // 세워두면 편집 중이 아닌데도 `AppModel.isRenaming`이 고착돼 B23 보류 로직이 잘못 걸리고
            // `applyRenameRequest`가 진입 실패를 성공으로 보고해 토큰을 조기 소비한다(재시도 경로 사망).
            guard cell.beginRename() else { return false }
            parent.onRenamingChanged(true)
            return true
        }

        /// 현재 선택 항목의 이름 변경 시작 (다중 선택이면 무동작 — UI설계 §6).
        private func beginRenameSelection() {
            guard let tableView else { return }
            guard tableView.selectedRowIndexes.count == 1,
                  let row = tableView.selectedRowIndexes.first,
                  row >= 0, row < items.count
            else { return }
            parent.onBeginRename(items[row].url)
        }

        // MARK: 키보드 (architect B4 — 원시 keyDown은 이 브릿지가 소유)

        /// - Returns: 이벤트를 소비했으면 `true` (NSTableView 기본 처리를 막는다)
        func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let tableView else { return false }
            // `.function`/`.numericPad`는 AppKit이 기능키에 자동으로 붙이는 플래그다.
            // 걸러내지 않으면 Home/End/PageUp/PageDown/F2/fn+Delete가 분기에 도달하지 못한다 (m2-impl T2).
            let modifiers = KeyScalar.userModifiers(of: event)
            let characters = event.charactersIgnoringModifiers ?? ""
            guard let scalar = characters.unicodeScalars.first else { return false }

            // Tab 순환은 T7(FocusBroker)에 위임
            if scalar == KeyScalar.tab && modifiers.isEmpty {
                parent.focusBroker.cycleFocus(from: .list)
                return true
            }

            if modifiers.contains(.command) {
                switch scalar {
                case KeyScalar.upArrow:
                    parent.onNavigateUp()
                    return true
                case KeyScalar.downArrow:
                    openSelection()
                    return true
                case KeyScalar.backspace:
                    // m2-impl T2/B2 — 휴지통 이동은 `Cmd+Backspace`.
                    // 단독 `Backspace`는 M1의 "상위 폴더 이동"으로 **그대로 둔다**.
                    // (명시 분기가 없으면 super.keyDown으로 흘러가 비프음이 난다)
                    parent.onDelete()
                    return true
                default:
                    return false
                }
            }

            guard modifiers.isEmpty || modifiers == .shift else { return false }

            switch scalar {
            case KeyScalar.carriageReturn, KeyScalar.enter, KeyScalar.newline:
                // Win10식: Enter = 열기 (설계서 §2.6)
                openSelection()
                return true

            case KeyScalar.backspace:
                // Backspace = 상위 폴더 (설계서 §2.6) — M2에서도 재할당 금지
                parent.onNavigateUp()
                return true

            case KeyScalar.home:
                selectRow(0, tableView: tableView)
                return true

            case KeyScalar.end:
                selectRow(items.count - 1, tableView: tableView)
                return true

            case KeyScalar.pageUp:
                movePage(by: -1, tableView: tableView)
                return true

            case KeyScalar.pageDown:
                movePage(by: 1, tableView: tableView)
                return true

            case KeyScalar.f5:
                parent.onRefresh()
                return true

            case KeyScalar.escape:
                resetTypeAhead()
                return false

            case KeyScalar.f2:
                // Win10식 이름 변경 (설계서 §2.6)
                beginRenameSelection()
                return true

            case KeyScalar.forwardDelete:
                // m2-impl T2/B2 — `fn+Delete`(⌦) = 휴지통 이동
                parent.onDelete()
                return true

            case KeyScalar.upArrow, KeyScalar.downArrow:
                // 방향키 선택 이동은 NSTableView 기본 처리에 맡긴다
                resetTypeAhead()
                return false

            default:
                break
            }

            return handleTypeAhead(characters: event.characters ?? "", scalar: scalar)
        }

        // MARK: 컨텍스트 메뉴 (M2 T7 / UI설계 §6)

        /// 메뉴 액션은 단축키와 **같은 콜백**을 호출한다 (중복 구현 금지 — T7 수용 기준).
        func makeContextMenu(forRow row: Int) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            // 이전 메뉴의 대상이 남지 않게 매번 초기화한다(빈 영역 메뉴에는 즐겨찾기 항목이 없다).
            favoriteTarget = nil

            if row >= 0, row < items.count {
                buildItemMenu(menu, clicked: items[row])
            } else {
                buildBackgroundMenu(menu)
            }
            return menu
        }

        private func buildItemMenu(_ menu: NSMenu, clicked: FileItem) {
            let selectionCount = tableView?.selectedRowIndexes.count ?? 0

            menu.addItem(makeItem("Open", #selector(menuOpen), key: "\r", modifiers: []))
            menu.addItem(.separator())
            menu.addItem(makeItem("Copy", #selector(menuCopy), key: "c", modifiers: .command))
            menu.addItem(makeItem("Cut", #selector(menuCut), key: "x", modifiers: .command))
            menu.addItem(.separator())
            menu.addItem(makeItem(
                "Rename",
                #selector(menuRename),
                key: String(KeyScalar.f2),
                modifiers: [],
                // 다중 선택 시 비활성 (UI설계 §6)
                enabled: selectionCount == 1
            ))
            menu.addItem(makeItem("Move to Trash", #selector(menuDelete), key: "\u{8}", modifiers: .command))
            menu.addItem(.separator())
            // architect B9 — Finder 정보창을 여는 공개 API가 없어 "Show in Finder"로 대체
            menu.addItem(makeItem("Show in Finder", #selector(menuRevealInFinder), key: "i", modifiers: .command))
            menu.addItem(.separator())

            // 즐겨찾기 토글 (2026-08-18). **등록/해제 중 하나만** 띄운다 —
            // 둘 다 띄우면 어느 쪽이 유효한지 사용자가 매번 추론해야 한다.
            // 대상은 "우클릭한 항목"으로 고정한다(선택이 그 사이 바뀌어도 흔들리지 않게).
            favoriteTarget = clicked.isDirectory ? clicked.url : nil
            let isRegistered = clicked.isDirectory && parent.isFavorite(clicked.url)
            menu.addItem(makeItem(
                isRegistered ? "Remove from Favorites" : "Add to Favorites",
                #selector(menuToggleFavorite),
                key: "t",
                modifiers: [.control, .command],
                // 폴더가 아닌 파일·다중 선택에는 비활성
                enabled: clicked.isDirectory && selectionCount == 1
            ))
        }

        private func buildBackgroundMenu(_ menu: NSMenu) {
            menu.addItem(makeItem("New Folder", #selector(menuNewFolder), key: "n", modifiers: [.command, .shift]))
            menu.addItem(.separator())
            menu.addItem(makeItem("Paste", #selector(menuPaste), key: "v", modifiers: .command, enabled: parent.canPaste))
            menu.addItem(.separator())

            let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            sortItem.submenu = makeSortMenu()
            menu.addItem(sortItem)
            menu.addItem(makeItem("Refresh", #selector(menuRefresh), key: "r", modifiers: .command))
        }

        private func makeSortMenu() -> NSMenu {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let descriptor = parent.sortDescriptor

            for key in SortKey.allCases {
                let item = makeItem(key.localizedTitle, #selector(menuSortKey(_:)), key: "", modifiers: [])
                item.representedObject = key.rawValue
                item.state = descriptor.key == key ? .on : .off
                submenu.addItem(item)
            }
            submenu.addItem(.separator())

            let ascending = makeItem("Ascending", #selector(menuSortAscending), key: "", modifiers: [])
            ascending.state = descriptor.ascending ? .on : .off
            submenu.addItem(ascending)

            let descending = makeItem("Descending", #selector(menuSortDescending), key: "", modifiers: [])
            descending.state = descriptor.ascending ? .off : .on
            submenu.addItem(descending)

            return submenu
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

        @objc private func menuOpen() { openSelection() }
        @objc private func menuCopy() { parent.onCopy() }
        @objc private func menuCut() { parent.onCut() }
        @objc private func menuPaste() { parent.onPaste() }
        @objc private func menuDelete() { parent.onDelete() }
        @objc private func menuRename() { beginRenameSelection() }
        @objc private func menuNewFolder() { parent.onNewFolder() }
        @objc private func menuRefresh() { parent.onRefresh() }
        @objc private func menuRevealInFinder() { parent.onRevealInFinder() }

        @objc private func menuToggleFavorite() {
            guard let url = favoriteTarget else { return }
            parent.onToggleFavorite(url)
        }

        /// 메뉴에서 기준만 고르는 경우 방향은 유지한다(헤더 클릭의 토글 규칙과 구분).
        @objc private func menuSortKey(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
            parent.onApplySort(FileSortDescriptor(key: key, ascending: parent.sortDescriptor.ascending))
        }

        @objc private func menuSortAscending() {
            parent.onApplySort(FileSortDescriptor(key: parent.sortDescriptor.key, ascending: true))
        }

        @objc private func menuSortDescending() {
            parent.onApplySort(FileSortDescriptor(key: parent.sortDescriptor.key, ascending: false))
        }

        // MARK: 타입-어헤드

        private func handleTypeAhead(characters: String, scalar: UnicodeScalar) -> Bool {
            let isSpace = scalar == KeyScalar.space
            let now = Date()
            let isContinuing = now.timeIntervalSince(typeAheadLastInput) < Self.typeAheadTimeout

            if isSpace {
                // UI설계 §9 — 입력 진행 중이면 검색 문자열에 포함, 그 외에는 QuickLook (M3 T4/B14).
                // **분기 구조는 M1 그대로다** — 우선순위 규칙은 이미 정확하므로 콜백만 꽂았다.
                guard isContinuing, !typeAheadBuffer.isEmpty else {
                    // 상위 알림(콜백) + 패널 토글. 패널 제어 자체는 브릿지가 소유한다(B15) —
                    // `QLPreviewPanel`은 responder chain을 요구하는데 그 위에 있는 건 이 브릿지뿐이다.
                    parent.onQuickLook()
                    toggleQuickLook()
                    return true
                }
            } else {
                // 제어 문자·기능키는 타입-어헤드 대상이 아니다
                guard scalar.value >= 0x20, !KeyScalar.isFunctionKey(scalar) else { return false }
                guard !characters.isEmpty else { return false }
            }

            if !isContinuing {
                typeAheadBuffer = ""
            }
            typeAheadBuffer += characters
            typeAheadLastInput = now
            parent.onTypeAhead(typeAheadBuffer)
            jumpToTypeAheadMatch()
            return true
        }

        private func resetTypeAhead() {
            typeAheadBuffer = ""
            typeAheadLastInput = .distantPast
        }

        private func jumpToTypeAheadMatch() {
            guard let tableView, !typeAheadBuffer.isEmpty, !items.isEmpty else { return }
            let prefix = typeAheadBuffer
            let start = tableView.selectedRow >= 0 ? tableView.selectedRow : 0

            // 현재 선택 다음 항목부터 순회(같은 접두어 항목 간 순환)
            let order = Array(start..<items.count) + Array(0..<start)
            let candidates = order.first { index in
                items[index].name.range(
                    of: prefix,
                    options: [.caseInsensitive, .diacriticInsensitive, .anchored],
                    range: nil,
                    locale: .current
                ) != nil
            }
            guard let match = candidates else { return }
            selectRow(match, tableView: tableView)
        }

        // MARK: 선택 이동

        private func selectRow(_ row: Int, tableView: NSTableView) {
            guard row >= 0, row < items.count else { return }
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }

        private func movePage(by direction: Int, tableView: NSTableView) {
            guard !items.isEmpty else { return }
            let visibleRows = max(1, Int(tableView.visibleRect.height / max(tableView.rowHeight, 1)) - 1)
            let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
            let target = min(max(current + direction * visibleRows, 0), items.count - 1)
            selectRow(target, tableView: tableView)
        }

        private func openSelection() {
            guard let tableView else { return }
            let selected = tableView.selectedRowIndexes.compactMap { row -> FileItem? in
                guard row >= 0, row < items.count else { return nil }
                return items[row]
            }
            guard !selected.isEmpty else { return }
            parent.onOpen(selected)
        }
    }
}
