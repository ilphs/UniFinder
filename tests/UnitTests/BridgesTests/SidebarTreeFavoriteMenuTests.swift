import AppKit
import XCTest
@testable import UniFinder

/// 트리 컨텍스트 메뉴의 즐겨찾기 토글 — 2026-08-18 사용자 요청 B단계.
///
/// **핵심 규약**: "즐겨찾기에서 제거"는 파일시스템을 건드리지 않는 별개 개념이라
/// 위험 대상 가드(`TreeModel.isProtectedNode` — rename/삭제 금지)와 **무관하게** 동작해야 한다.
/// 이 가드로 비활성화하면 즐겨찾기 항목을 영영 목록에서 뺄 수 없다.
@MainActor
final class SidebarTreeFavoriteMenuTests: TempDirectoryTestCase {

    /// 아웃라인 뷰가 테스트 도중 해제되지 않게 붙잡아 둔다.
    /// (`tearDownWithError`는 nonisolated라 여기서 비우지 않고 케이스 인스턴스 수명에 맡긴다)
    private var retainedViews: [NSView] = []

    private func makeDefaults() -> UserDefaults {
        let name = "com.unifinder.tests.treemenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeEmptySettings() -> AppSettings {
        let settings = AppSettings(defaults: makeDefaults())
        for url in settings.favoriteURLs { settings.removeFavorite(url) }
        return settings
    }

    private func makeCoordinator(
        model: TreeModel,
        isFavorite: @escaping (URL) -> Bool = { _ in false },
        onToggleFavorite: @escaping (URL) -> Void = { _ in }
    ) -> SidebarTreeBridge.Coordinator {
        let bridge = SidebarTreeBridge(
            model: model,
            revision: model.revision,
            focusBroker: FocusBroker(),
            onSelect: { _ in },
            onRefresh: {},
            isFavorite: isFavorite,
            onToggleFavorite: onToggleFavorite
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

    /// 아웃라인 뷰에서 해당 URL의 폴더 노드를 펼친다 — 섹션만 펼치면 그 하위 폴더의 자식 행이 생기지 않는다.
    private func expandNode(_ url: URL, in coordinator: SidebarTreeBridge.Coordinator, model: TreeModel) throws {
        let outlineView = try XCTUnwrap(coordinator.outlineView)
        let node = try XCTUnwrap(model.node(for: url))
        outlineView.expandItem(node)
    }

    private func favoriteRow(in coordinator: SidebarTreeBridge.Coordinator, url: URL) throws -> Int {
        let outlineView = try XCTUnwrap(coordinator.outlineView)
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? TreeNode else { continue }
            if node.kind == .folder, PathKey.isSame(node.url, url) { return row }
        }
        throw XCTSkip("트리에서 대상 노드를 찾지 못함")
    }

    // MARK: -

    func testTreeContextMenu_registeredFavorite_showsRemoveAndKeepsItEnabled() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let settings = makeEmptySettings()
        settings.addFavorite(folder)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)
        let coordinator = makeCoordinator(model: model, isFavorite: { settings.isFavorite($0) })

        let row = try favoriteRow(in: coordinator, url: folder)
        let menu = try XCTUnwrap(coordinator.makeContextMenu(forRow: row))
        let favoriteItems = menu.items.filter { $0.title.hasSuffix("Favorites") }

        XCTAssertEqual(favoriteItems.map(\.title), ["Remove from Favorites"], "등록/해제가 동시에 노출됐다")
        XCTAssertEqual(
            favoriteItems.first?.isEnabled,
            true,
            "위험 대상 가드가 즐겨찾기 해제까지 막았다 — 해제는 파일시스템과 무관한 별개 개념이다"
        )

        // 같은 메뉴에서 rename/삭제는 **여전히 비활성**이어야 한다(보호 가드 회귀 확인).
        XCTAssertEqual(menu.items.first { $0.title == "Rename" }?.isEnabled, false)
        XCTAssertEqual(menu.items.first { $0.title == "Move to Trash" }?.isEnabled, false)
    }

    func testTreeContextMenu_unregisteredFolder_showsAdd() async throws {
        let child = try Fixture.makeDirectory(in: testRoot, name: "Child")
        let settings = makeEmptySettings()
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)
        let homeRoot = try XCTUnwrap(model.node(for: testRoot))
        await model.expand(homeRoot)

        let coordinator = makeCoordinator(model: model, isFavorite: { settings.isFavorite($0) })
        try expandNode(testRoot, in: coordinator, model: model)
        let row = try favoriteRow(in: coordinator, url: child)
        let menu = try XCTUnwrap(coordinator.makeContextMenu(forRow: row))

        XCTAssertEqual(
            menu.items.filter { $0.title.hasSuffix("Favorites") }.map(\.title),
            ["Add to Favorites"]
        )
    }

    /// 메뉴 액션이 **우클릭한 노드**를 대상으로 전달하는지.
    func testTreeContextMenu_toggleAction_targetsClickedNode() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let settings = makeEmptySettings()
        settings.addFavorite(folder)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)

        var toggled: [URL] = []
        let coordinator = makeCoordinator(
            model: model,
            isFavorite: { settings.isFavorite($0) },
            onToggleFavorite: { toggled.append($0) }
        )

        let row = try favoriteRow(in: coordinator, url: folder)
        let menu = try XCTUnwrap(coordinator.makeContextMenu(forRow: row))
        let item = try XCTUnwrap(menu.items.first { $0.title.hasSuffix("Favorites") })
        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(toggled.map(PathKey.key), [PathKey.key(folder)])
    }
}
