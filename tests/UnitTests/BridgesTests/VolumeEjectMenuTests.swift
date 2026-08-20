import AppKit
import XCTest
@testable import UniFinder

/// Eject 컨텍스트 메뉴 진입점 — 사이드바 트리 + 우측 목록 (2026-08-20).
///
/// 정책: **대상일 때만 항목을 넣는다**(비활성으로 두지 않는다). 트리·목록의 대다수 항목은
/// 일반 폴더/파일이라 항상 넣으면 죽은 Eject가 상시로 보인다 — Finder도 볼륨에서만 보여준다.
///
/// **주의**: `M2BridgeSmokeTests.testItemContextMenu_matchesSpecOrderAndDisablesRenameOnMultipleSelection`이
/// 목록 메뉴 타이틀 배열을 하드코딩한다. Eject는 **조건부**라 일반 항목 메뉴에는 나타나지 않으므로
/// 그 배열은 그대로 유효하다 — 이 파일의 `testItemMenu_plainFolder_hasNoEject`가 그 전제를 지킨다.
@MainActor
final class VolumeEjectMenuTests: TempDirectoryTestCase {

    /// 아웃라인/테이블 뷰는 Coordinator가 weak으로 들고 있어 테스트가 붙잡아 둬야 한다
    /// (`OpenInNewWindowMenuTests` 선례). 케이스 인스턴스와 함께 해제된다.
    private var retainedViews: [NSView] = []

    private func makeSettings() -> AppSettings {
        let name = "com.unifinder.tests.eject.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return AppSettings(defaults: defaults)
    }

    // MARK: - 사이드바 트리

    private func makeTreeCoordinator(
        model: TreeModel,
        canEject: @escaping (URL) -> Bool,
        onEject: @escaping (URL) -> Void = { _ in }
    ) -> SidebarTreeBridge.Coordinator {
        let bridge = SidebarTreeBridge(
            model: model,
            revision: model.revision,
            focusBroker: FocusBroker(),
            onSelect: { _ in },
            onRefresh: {},
            canEject: canEject,
            onEject: onEject
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

    private func row(in coordinator: SidebarTreeBridge.Coordinator, url: URL) throws -> Int {
        let outlineView = try XCTUnwrap(coordinator.outlineView)
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? TreeNode, node.kind == .folder else { continue }
            if PathKey.isSame(node.url, url) { return row }
        }
        throw XCTSkip("트리에서 대상 노드를 찾지 못함")
    }

    private func treeModel(volumes: [URL], settings: AppSettings) -> TreeModel {
        let service = VolumeService(
            enumerator: { _, _ in volumes },
            attributeReader: { url in
                .init(isLocal: true, isBrowsable: true, name: url.lastPathComponent, isRootFileSystem: false)
            }
        )
        return TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings, volumeService: service)
    }

    func testTreeMenu_ejectableVolume_hasEjectItemThatRoutesToTheNode() throws {
        let dmg = try Fixture.makeDirectory(in: testRoot, name: "Installer")
        let model = treeModel(volumes: [dmg], settings: makeSettings())
        var ejected: [URL] = []
        let coordinator = makeTreeCoordinator(
            model: model,
            canEject: { PathKey.isSame($0, dmg) },
            onEject: { ejected.append($0) }
        )

        let menu = try XCTUnwrap(coordinator.makeContextMenu(forRow: try row(in: coordinator, url: dmg)))
        let eject = try XCTUnwrap(menu.items.first { $0.title == "Eject" })

        XCTAssertTrue(eject.isEnabled)
        XCTAssertEqual(eject.keyEquivalent, "", "Eject에는 단축키를 주지 않는다(Finder와 동일)")

        _ = eject.target?.perform(eject.action, with: eject)
        XCTAssertEqual(ejected.map(\.path), [dmg.path])
    }

    /// 항목 순서 — `Open` 그룹 바로 아래다(Finder/Win10 탐색기와 같은 자리).
    func testTreeMenu_ejectSitsRightAfterTheOpenGroup() throws {
        let dmg = try Fixture.makeDirectory(in: testRoot, name: "Installer")
        let model = treeModel(volumes: [dmg], settings: makeSettings())
        let coordinator = makeTreeCoordinator(model: model, canEject: { PathKey.isSame($0, dmg) })

        let menu = try XCTUnwrap(coordinator.makeContextMenu(forRow: try row(in: coordinator, url: dmg)))
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(Array(titles.prefix(3)), ["Open", "Open in New Window", "Eject"])
    }

    func testTreeMenu_plainFolder_hasNoEjectItem() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Documents")
        let settings = makeSettings()
        settings.addFavorite(folder)
        let model = treeModel(volumes: [], settings: settings)
        let coordinator = makeTreeCoordinator(model: model, canEject: { _ in false })

        let menu = try XCTUnwrap(coordinator.makeContextMenu(forRow: try row(in: coordinator, url: folder)))

        XCTAssertNil(
            menu.items.first { $0.title == "Eject" },
            "일반 폴더 우클릭에 죽은 Eject가 보이면 안 된다"
        )
    }

    // MARK: - 우측 목록 (`/Volumes`를 열었을 때)

    private func makeListCoordinator(
        items: [FileItem],
        selectedRows: IndexSet,
        canEject: @escaping (URL) -> Bool,
        onEject: @escaping (URL) -> Void = { _ in }
    ) -> FileListBridge.Coordinator {
        // 인자 순서는 `FileListBridge`의 프로퍼티 선언 순서를 따른다(구조체 memberwise init).
        let bridge = FileListBridge(
            items: items,
            revision: 1,
            sortDescriptor: .default,
            selection: .constant([]),
            currentDirectory: testRoot,
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "VolumeEjectMenu-\(UUID().uuidString)")!),
            onOpen: { _ in },
            onNavigateUp: {},
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: { _ in },
            canEject: canEject,
            onEject: onEject
        )
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        retainedViews.append(tableView)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(SortKey.name.columnIdentifier))
        tableView.addTableColumn(column)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.items = items
        tableView.reloadData()
        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        return coordinator
    }

    private func makeItem(name: String, isDirectory: Bool = true) -> FileItem {
        FileItem(
            url: testRoot.appendingPathComponent(name, isDirectory: isDirectory),
            name: name,
            isDirectory: isDirectory,
            isHidden: false,
            isSymlink: false,
            size: isDirectory ? nil : 10,
            modifiedAt: nil,
            typeDescription: isDirectory ? "Folder" : "Document"
        )
    }

    func testItemMenu_mountedVolume_hasEjectItemThatRoutesToTheClickedItem() throws {
        let volume = makeItem(name: "Installer")
        var ejected: [URL] = []
        let coordinator = makeListCoordinator(
            items: [volume],
            selectedRows: IndexSet([0]),
            canEject: { PathKey.isSame($0, volume.url) },
            onEject: { ejected.append($0) }
        )

        let menu = coordinator.makeContextMenu(forRow: 0)
        let eject = try XCTUnwrap(menu.items.first { $0.title == "Eject" })

        _ = eject.target?.perform(eject.action, with: eject)
        XCTAssertEqual(ejected.map { PathKey.key($0) }, [PathKey.key(volume.url)])
    }

    /// 일반 폴더/파일에는 항목이 없다 — `M2BridgeSmokeTests`의 하드코딩된 타이틀 배열이
    /// 계속 유효하려면 이 전제가 유지돼야 한다.
    func testItemMenu_plainFolder_hasNoEject() {
        let folder = makeItem(name: "Documents")
        let coordinator = makeListCoordinator(items: [folder], selectedRows: IndexSet([0]), canEject: { _ in false })

        let titles = coordinator.makeContextMenu(forRow: 0).items.map(\.title)

        XCTAssertFalse(titles.contains("Eject"))
    }

    /// 다중 선택에서는 넣지 않는다 — 실패가 섞였을 때 무엇이 남았는지 알릴 방법이 없다
    /// (`Rename`·`Get Info`와 같은 단일 선택 규칙).
    func testItemMenu_multipleSelection_hasNoEject() {
        let first = makeItem(name: "Installer")
        let second = makeItem(name: "Backup")
        let coordinator = makeListCoordinator(
            items: [first, second],
            selectedRows: IndexSet([0, 1]),
            canEject: { _ in true }
        )

        let titles = coordinator.makeContextMenu(forRow: 0).items.map(\.title)

        XCTAssertFalse(titles.contains("Eject"))
    }

    /// 빈 영역 우클릭에는 대상이 없다.
    func testBackgroundMenu_hasNoEject() {
        let coordinator = makeListCoordinator(items: [], selectedRows: IndexSet(), canEject: { _ in true })

        let titles = coordinator.makeContextMenu(forRow: -1).items.map(\.title)

        XCTAssertFalse(titles.contains("Eject"))
    }
}
