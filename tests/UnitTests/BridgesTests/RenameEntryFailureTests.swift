import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// **M2 백로그 회귀** — 인라인 편집 **진입 실패**를 성공으로 오보고하던 결함 (목록/트리 공통).
///
/// `InlineNameEditor.begin(target:)`은 셀이 아직 윈도우에 붙기 전이면(`field.window == nil`)
/// `finish(commit: false)`로 조용히 되돌아간다. 그런데 브릿지는 그 전에 이미
/// `onRenamingChanged(true)`를 부르고 무조건 성공을 보고했다. 결과:
/// - `AppModel.isRenaming`이 **true로 고착** — 편집 중이 아닌데 B23 보류/포커스 억제가 걸린다
/// - `applyRenameRequest`가 토큰을 **조기 소비** — 목록이 채워진 뒤 재시도가 불가능해진다
///   (M2 리뷰에서 major로 지적된 "새 폴더 생성 직후 rename" 결함과 같은 계열)
@MainActor
final class RenameEntryFailureTests: TempDirectoryTestCase {

    /// 브릿지가 weak로만 잡는 뷰들 — 테스트가 강한 참조를 유지해야 한다.
    private var retainedViews: [NSView] = []
    /// 셀의 `window`는 뷰 계층에서 파생될 뿐 강한 참조가 아니다 — 윈도우를 놓으면
    /// "붙어 있음"을 전제한 케이스가 진입 실패로 뒤집힌다.
    private var retainedWindows: [NSWindow] = []

    // MARK: - 목록 브릿지

    private func makeItem(name: String) -> FileItem {
        FileItem(
            url: testRoot.appendingPathComponent(name),
            name: name,
            isDirectory: false,
            isHidden: false,
            isSymlink: false,
            size: 10,
            modifiedAt: Fixture.fixedDate(),
            typeDescription: "파일"
        )
    }

    /// - Parameter attachedToWindow: 셀이 윈도우에 붙는지 (= 편집 진입 가능 여부)
    private func makeListCoordinator(
        items: [FileItem],
        attachedToWindow: Bool,
        onRenamingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> FileListBridge.Coordinator {
        var selection = Set<URL>()
        let bridge = FileListBridge(
            items: items,
            revision: 1,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "RenameEntry-\(UUID().uuidString)")!),
            onOpen: { _ in },
            onNavigateUp: {},
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: { _ in },
            onRenamingChanged: onRenamingChanged
        )
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        retainedViews.append(tableView)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(SortKey.name.columnIdentifier)))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        if attachedToWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(tableView)
            retainedWindows.append(window)
        }
        coordinator.tableView = tableView
        coordinator.items = items
        tableView.reloadData()
        return coordinator
    }

    func testListBeginRename_whenCellIsNotInWindow_reportsFailureInsteadOfPretendingSuccess() {
        let item = makeItem(name: "a.txt")
        var renamingFlags: [Bool] = []
        let coordinator = makeListCoordinator(
            items: [item],
            attachedToWindow: false,
            onRenamingChanged: { renamingFlags.append($0) }
        )

        let entered = coordinator.beginRename(at: item.url)

        XCTAssertFalse(entered, "편집기가 진입하지 못했는데 성공으로 보고하면 안 된다")
        XCTAssertFalse(
            renamingFlags.contains(true),
            "진입 실패인데 `isRenaming`을 세우면 편집 중이 아닌 상태로 고착된다(B23 보류가 잘못 걸린다)"
        )
    }

    func testListRenameRequest_whenEntryFails_keepsTokenForRetryAndSucceedsOnceAttachedToWindow() {
        let item = makeItem(name: "a.txt")
        let detached = makeListCoordinator(items: [item], attachedToWindow: false)
        let request = AppModel.RenameRequest(url: item.url, token: 11)

        XCTAssertTrue(detached.scheduleRenameIfNeeded(request))
        XCTAssertFalse(detached.applyRenameRequest(request))
        XCTAssertNotEqual(
            detached.appliedRenameToken, request.token,
            "진입 실패로 토큰이 소비되면 재시도 경로(maxRenameAttempts)가 통째로 죽는다"
        )
        XCTAssertTrue(detached.scheduleRenameIfNeeded(request), "소비되지 않은 토큰은 다시 예약되어야 한다")

        // 같은 요청이 윈도우에 붙은 목록에 도착하면 이번엔 성공한다.
        var renamingFlags: [Bool] = []
        let attached = makeListCoordinator(
            items: [item],
            attachedToWindow: true,
            onRenamingChanged: { renamingFlags.append($0) }
        )
        XCTAssertTrue(attached.scheduleRenameIfNeeded(request))
        XCTAssertTrue(attached.applyRenameRequest(request), "윈도우에 붙은 셀에서는 편집에 진입해야 한다")
        XCTAssertEqual(attached.appliedRenameToken, request.token)
        XCTAssertEqual(renamingFlags.last, true, "진입에 성공했으면 편집 중 상태를 세워야 한다")
    }

    /// 진입 실패가 반복되어도 상한을 넘으면 포기한다(무한 재시도 방지 — 기존 규약 유지).
    func testListRenameRequest_repeatedEntryFailure_stillGivesUpAtAttemptCap() {
        let item = makeItem(name: "a.txt")
        let coordinator = makeListCoordinator(items: [item], attachedToWindow: false)
        let request = AppModel.RenameRequest(url: item.url, token: 12)

        for _ in 0..<FileListBridge.Coordinator.maxRenameAttempts {
            _ = coordinator.scheduleRenameIfNeeded(request)
            XCTAssertFalse(coordinator.applyRenameRequest(request))
        }

        XCTAssertFalse(coordinator.scheduleRenameIfNeeded(request), "상한을 넘으면 재시도를 포기해야 한다")
    }

    /// 셀 자체의 계약: 윈도우에 붙기 전에는 편집이 시작되지 않으므로 `false`를 돌려줘야 한다.
    func testNameCell_beginRename_returnsActualEditingState() {
        let cell = FileNameCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        cell.configure(with: makeItem(name: "a.txt"), iconProvider: IconProvider { _ in nil })

        XCTAssertFalse(cell.beginRename(), "윈도우에 붙기 전에는 편집이 시작되지 않는다")
        XCTAssertFalse(cell.nameEditor.isEditing)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        retainedWindows.append(window)
        window.contentView?.addSubview(cell)
        XCTAssertTrue(cell.beginRename(), "윈도우에 붙은 뒤에는 편집에 진입해야 한다")
        XCTAssertTrue(cell.nameEditor.isEditing)
    }

    func testTreeNodeCell_beginRename_returnsActualEditingState() {
        let cell = TreeNodeCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        let node = TreeNode(kind: .folder, url: testRoot, name: "root", isSymlink: false, parent: nil)
        cell.configure(node: node, folderIcon: NSImage(size: NSSize(width: 16, height: 16)))

        XCTAssertFalse(cell.beginRename(), "목록 셀과 같은 규칙 — 윈도우 없이는 편집이 시작되지 않는다")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        retainedWindows.append(window)
        window.contentView?.addSubview(cell)
        XCTAssertTrue(cell.beginRename())
    }

    // MARK: - 트리 브릿지 (같은 계열 결함)

    private func makeTreeCoordinator(
        model: TreeModel,
        attachedToWindow: Bool,
        onRenamingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> SidebarTreeBridge.Coordinator {
        let bridge = SidebarTreeBridge(
            model: model,
            revision: model.revision,
            focusBroker: FocusBroker(),
            onSelect: { _ in },
            onRefresh: {},
            onRenamingChanged: onRenamingChanged
        )
        let coordinator = bridge.makeCoordinator()
        let outlineView = KeyRoutingOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        retainedViews.append(outlineView)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        if attachedToWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(outlineView)
            retainedWindows.append(window)
        }
        coordinator.outlineView = outlineView
        outlineView.reloadData()
        for section in model.sections {
            outlineView.expandItem(section)
        }
        return coordinator
    }

    /// 트리에 실제 행이 생기도록 홈 루트를 확장해 둔다.
    private func makeExpandedTreeModel(childName: String) async throws -> (TreeModel, URL) {
        let child = try Fixture.makeDirectory(in: testRoot, name: childName)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = model.node(for: testRoot) else {
            throw XCTSkip("홈 루트 노드를 만들 수 없음")
        }
        await model.expand(homeRoot)
        return (model, child)
    }

    func testTreeBeginRename_whenCellIsNotInWindow_reportsFailureAndKeepsTokenForRetry() async throws {
        let (model, child) = try await makeExpandedTreeModel(childName: "A")
        var renamingFlags: [Bool] = []
        let coordinator = makeTreeCoordinator(
            model: model,
            attachedToWindow: false,
            onRenamingChanged: { renamingFlags.append($0) }
        )
        guard let homeRoot = model.node(for: testRoot) else { return XCTFail("홈 루트 노드 없음") }
        coordinator.outlineView?.expandItem(homeRoot)
        guard let node = model.node(for: child), (coordinator.outlineView?.row(forItem: node) ?? -1) >= 0 else {
            throw XCTSkip("트리에 대상 노드 행이 만들어지지 않음")
        }

        let request = AppModel.RenameRequest(url: child, token: 21)
        XCTAssertTrue(coordinator.scheduleRenameIfNeeded(request))
        XCTAssertFalse(coordinator.applyRenameRequest(request), "진입하지 못했으면 실패를 보고해야 한다")
        XCTAssertFalse(
            renamingFlags.contains(true),
            "진입 실패인데 `isRenaming`을 세우면 편집 중이 아닌 상태로 고착된다"
        )
        XCTAssertNotEqual(
            coordinator.appliedRenameToken, request.token,
            "트리도 목록과 같은 규칙 — 진입 실패는 토큰 소비로 치지 않는다"
        )
    }

    func testTreeBeginRename_whenAttachedToWindow_entersEditingAndConsumesToken() async throws {
        let (model, child) = try await makeExpandedTreeModel(childName: "A")
        var renamingFlags: [Bool] = []
        let coordinator = makeTreeCoordinator(
            model: model,
            attachedToWindow: true,
            onRenamingChanged: { renamingFlags.append($0) }
        )
        guard let homeRoot = model.node(for: testRoot) else { return XCTFail("홈 루트 노드 없음") }
        coordinator.outlineView?.expandItem(homeRoot)
        guard let node = model.node(for: child), (coordinator.outlineView?.row(forItem: node) ?? -1) >= 0 else {
            throw XCTSkip("트리에 대상 노드 행이 만들어지지 않음")
        }

        let request = AppModel.RenameRequest(url: child, token: 22)
        XCTAssertTrue(coordinator.scheduleRenameIfNeeded(request))
        XCTAssertTrue(coordinator.applyRenameRequest(request), "윈도우에 붙은 셀에서는 편집에 진입해야 한다")
        XCTAssertEqual(coordinator.appliedRenameToken, request.token)
        XCTAssertEqual(renamingFlags.last, true)
    }
}
