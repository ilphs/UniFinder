import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// "Open in New Window" 컨텍스트 메뉴 진입점 — 다중 창 지원(New Window).
///
/// 사이드바 트리와 파일 목록 양쪽에 같은 진입점을 추가한다: 폴더를 우클릭하면 그 폴더를 시작
/// 위치로 하는 새 창을 열 수 있어야 한다. 목록에서는 파일도 우클릭 대상이 될 수 있으므로
/// 그 경우에는 항목이 있되 **비활성**이어야 한다(트리는 애초에 폴더만 노드로 갖는다).
///
/// **주의**: 기존 `M2BridgeSmokeTests.testItemContextMenu_matchesSpecOrderAndDisablesRenameOnMultipleSelection`은
/// 목록 컨텍스트 메뉴 타이틀 배열을 정확한 순서로 하드코딩하고 있다
/// (`["Open", "Copy", "Cut", "Rename", "Move to Trash", "Show in Finder", "Add to Favorites"]`).
/// "Open in New Window" 항목이 그 메뉴에 추가되면 이 배열 검사가 항목 개수 불일치로 실패한다 —
/// 리포트 참조. 여기서는 그 파일을 건드리지 않고 새 항목의 존재/활성 조건만 별도로 검증한다.
@MainActor
final class OpenInNewWindowMenuTests: TempDirectoryTestCase {

    /// 아웃라인/테이블 뷰가 테스트 도중 해제되지 않게 붙잡아 둔다.
    private var retainedViews: [NSView] = []
    private var retainedWindows: [NSWindow] = []

    // MARK: - 사이드바 트리

    private func makeTreeSettings() -> AppSettings {
        let name = "com.unifinder.tests.openinnewwindow.tree.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return AppSettings(defaults: defaults)
    }

    private func makeTreeCoordinator(
        model: TreeModel,
        onOpenInNewWindow: @escaping (URL) -> Void = { _ in }
    ) -> SidebarTreeBridge.Coordinator {
        let bridge = SidebarTreeBridge(
            model: model,
            revision: model.revision,
            focusBroker: FocusBroker(),
            onSelect: { _ in },
            onRefresh: {},
            onOpenInNewWindow: onOpenInNewWindow
        )
        let coordinator = bridge.makeCoordinator()
        let outlineView = KeyRoutingOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        retainedViews.append(outlineView)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.outlineView = outlineView
        outlineView.reloadData()
        for section in model.sections {
            outlineView.expandItem(section)
        }
        return coordinator
    }

    private func favoriteRow(in coordinator: SidebarTreeBridge.Coordinator, url: URL) throws -> Int {
        let outlineView = try XCTUnwrap(coordinator.outlineView)
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? TreeNode else { continue }
            if node.kind == .folder, PathKey.isSame(node.url, url) { return row }
        }
        throw XCTSkip("트리에서 대상 노드를 찾지 못함")
    }

    func testTreeContextMenu_folderNode_containsOpenInNewWindow() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let settings = makeTreeSettings()
        settings.addFavorite(folder)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)
        let coordinator = makeTreeCoordinator(model: model)

        let row = try favoriteRow(in: coordinator, url: folder)
        let menu = try XCTUnwrap(coordinator.makeContextMenu(forRow: row))

        XCTAssertTrue(
            menu.items.contains { $0.title == "Open in New Window" },
            "트리 폴더 노드 컨텍스트 메뉴에 'Open in New Window'가 없다"
        )
    }

    func testTreeContextMenu_openInNewWindow_invokesCallbackWithClickedNodeURL() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let settings = makeTreeSettings()
        settings.addFavorite(folder)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)

        var opened: [URL] = []
        let coordinator = makeTreeCoordinator(model: model, onOpenInNewWindow: { opened.append($0) })

        let row = try favoriteRow(in: coordinator, url: folder)
        let menu = try XCTUnwrap(coordinator.makeContextMenu(forRow: row))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open in New Window" })
        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(opened.map(PathKey.key), [PathKey.key(folder)], "콜백이 우클릭한 노드의 URL로 호출되지 않았다")
    }

    // MARK: - 파일 목록

    private func makeItem(name: String, isDirectory: Bool) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/open-in-new-window").appendingPathComponent(name, isDirectory: isDirectory),
            name: name,
            isDirectory: isDirectory,
            isHidden: false,
            isSymlink: false,
            size: 10,
            modifiedAt: Fixture.fixedDate(),
            typeDescription: isDirectory ? "폴더" : "파일"
        )
    }

    private func makeListBridge(
        items: [FileItem],
        onOpenInNewWindow: @escaping (URL) -> Void = { _ in }
    ) -> FileListBridge {
        var selection = Set<URL>()
        return FileListBridge(
            items: items,
            revision: 1,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "OpenInNewWindow-List-\(UUID().uuidString)")!),
            onOpen: { _ in },
            onNavigateUp: {},
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: { _ in },
            onOpenInNewWindow: onOpenInNewWindow
        )
    }

    private func makeListCoordinator(
        items: [FileItem],
        selectedRows: IndexSet = [],
        onOpenInNewWindow: @escaping (URL) -> Void = { _ in }
    ) -> FileListBridge.Coordinator {
        let bridge = makeListBridge(items: items, onOpenInNewWindow: onOpenInNewWindow)
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        retainedViews.append(tableView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(tableView)
        retainedWindows.append(window)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(SortKey.name.columnIdentifier)))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.items = items
        tableView.reloadData()
        if !selectedRows.isEmpty {
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        }
        return coordinator
    }

    func testListContextMenu_folderItem_enablesOpenInNewWindow() {
        let folder = makeItem(name: "docs", isDirectory: true)
        let coordinator = makeListCoordinator(items: [folder], selectedRows: IndexSet(integer: 0))

        let menu = coordinator.makeContextMenu(forRow: 0)
        let item = menu.items.first { $0.title == "Open in New Window" }

        XCTAssertNotNil(item, "목록 컨텍스트 메뉴에 'Open in New Window'가 없다")
        XCTAssertEqual(item?.isEnabled, true, "폴더 항목에서는 활성이어야 한다")
    }

    func testListContextMenu_fileItem_disablesOpenInNewWindow() {
        let file = makeItem(name: "a.txt", isDirectory: false)
        let coordinator = makeListCoordinator(items: [file], selectedRows: IndexSet(integer: 0))

        let menu = coordinator.makeContextMenu(forRow: 0)
        let item = menu.items.first { $0.title == "Open in New Window" }

        XCTAssertNotNil(item, "파일 항목에도 메뉴 항목 자체는 있어야 한다(비활성으로 존재)")
        XCTAssertEqual(item?.isEnabled, false, "파일 항목에서는 새 창으로 열 수 없으므로 비활성이어야 한다")
    }

    func testListContextMenu_openInNewWindow_invokesCallbackWithClickedItemURL() {
        let folder = makeItem(name: "docs", isDirectory: true)
        let other = makeItem(name: "other", isDirectory: true)
        var opened: [URL] = []
        let coordinator = makeListCoordinator(
            items: [folder, other],
            selectedRows: IndexSet(integer: 0),
            onOpenInNewWindow: { opened.append($0) }
        )

        let menu = coordinator.makeContextMenu(forRow: 0)
        let item = menu.items.first { $0.title == "Open in New Window" }
        _ = item?.target?.perform(item?.action, with: item)

        XCTAssertEqual(opened.map(PathKey.key), [PathKey.key(folder.url)], "콜백이 클릭한 항목의 URL과 일치하지 않는다")
    }
}
