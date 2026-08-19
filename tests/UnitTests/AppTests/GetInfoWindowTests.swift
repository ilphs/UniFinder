import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// Get Info 창의 배선과 **`Cmd+I` 소유권** (후속 T5 / UI설계 §10 불변식 · D2).
///
/// 이 파일이 지키는 불변식은 하나로 요약된다:
/// **`Cmd+I`를 단 항목은 앱 전체에서 정확히 하나이며, 그것은 `Get Info`다.**
/// AppKit은 `Cmd` 단축키를 responder chain보다 메인 메뉴에서 먼저 찾으므로, 같은 단축키를 단
/// 항목이 둘이면 어느 쪽이 잡히는지가 메뉴 순서라는 우연에 좌우된다.
@MainActor
final class GetInfoWindowTests: TempDirectoryTestCase {

    private var retainedViews: [NSView] = []
    private var retainedWindows: [NSWindow] = []

    // MARK: - 씬 등록

    /// 씬 타입 이름으로 확인한다 — 테스트는 앱을 띄우지 않는다(`MultiWindowSceneTests`와 같은 방식).
    func testApp_registersInfoAndDiskCapacityScenes() {
        let sceneType = String(describing: type(of: UniFinderApp().body))

        XCTAssertTrue(sceneType.contains("WindowGroup"), "메인 씬은 여전히 WindowGroup이어야 한다: \(sceneType)")
        XCTAssertTrue(
            sceneType.contains("Window<"),
            "디스크 용량 창은 단일 `Window` 씬이어야 한다(창 1개만 뜬다 — D9): \(sceneType)"
        )
        XCTAssertEqual(UniFinderApp.infoWindowID, "info")
        XCTAssertEqual(UniFinderApp.diskCapacityWindowID, "disk-capacity")
    }

    // MARK: - 대상 선정 (D2)

    func testInfoTarget_isNilUnlessExactlyOneItemIsSelected() throws {
        let file = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let other = try Fixture.makeFile(in: testRoot, name: "b.txt")
        let model = AppModel(startURL: testRoot)

        XCTAssertNil(model.infoTarget, "선택이 없으면 대상이 없다")

        model.directory.selection = [file]
        XCTAssertEqual(model.infoTarget?.lastPathComponent, "a.txt")

        model.directory.selection = [file, other]
        XCTAssertNil(
            model.infoTarget,
            "다중 선택에서 첫 항목만 보여주면 사용자가 고른 대상과 창의 대상이 달라진다 — 비활성이 정직하다(D2)"
        )
    }

    // MARK: - 컨텍스트 메뉴의 ⌘I 소유권

    private func makeCoordinator(items: [FileItem], selectedRows: IndexSet) -> FileListBridge.Coordinator {
        var selection = Set<URL>()
        let bridge = FileListBridge(
            items: items,
            revision: 1,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "GetInfo-\(UUID().uuidString)")!),
            onOpen: { _ in },
            onNavigateUp: {},
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: { _ in }
        )
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        retainedViews.append(tableView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(tableView)
        retainedWindows.append(window)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(SortKey.name.columnIdentifier)))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.items = items
        tableView.reloadData()
        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        return coordinator
    }

    private func makeItem(_ name: String) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/get-info").appendingPathComponent(name),
            name: name, isDirectory: false, isHidden: false, isSymlink: false,
            size: 1, modifiedAt: nil, typeDescription: "Document"
        )
    }

    func testContextMenu_getInfoOwnsCommandIAndShowInFinderHasNoShortcut() {
        let coordinator = makeCoordinator(items: [makeItem("a.txt")], selectedRows: IndexSet(integer: 0))

        let menu = coordinator.makeContextMenu(forRow: 0)
        let commandI = menu.items.filter {
            $0.keyEquivalent == "i" && $0.keyEquivalentModifierMask.contains(.command)
        }

        XCTAssertEqual(commandI.map(\.title), ["Get Info"], "⌘I 소유자가 정확히 하나가 아니다")

        let showInFinder = menu.items.first { $0.title == "Show in Finder" }
        XCTAssertEqual(showInFinder?.keyEquivalent, "", "Show in Finder는 단축키를 갖지 않는다(B9 승계)")
        XCTAssertNotNil(showInFinder, "항목 자체는 남아야 한다 — Finder로 보내는 것은 여전히 유용하다")
    }

    func testContextMenu_getInfoInvokesCallbackWithClickedItem() {
        let item = makeItem("a.txt")
        var opened: [URL] = []
        var selection = Set<URL>()
        var bridge = FileListBridge(
            items: [item],
            revision: 1,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "GetInfo-CB-\(UUID().uuidString)")!),
            onOpen: { _ in }, onNavigateUp: {}, onSortChange: { _ in }, onRefresh: {}, onTypeAhead: { _ in }
        )
        bridge.onGetInfo = { opened.append($0) }
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        retainedViews.append(tableView)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(SortKey.name.columnIdentifier)))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.items = [item]
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let menu = coordinator.makeContextMenu(forRow: 0)
        let getInfo = menu.items.first { $0.title == "Get Info" }
        _ = getInfo?.target?.perform(getInfo?.action, with: getInfo)

        XCTAssertEqual(opened.map(\.path), [item.url.path])
    }

    // MARK: - 소스 수준 봉인 (메뉴바)

    /// SwiftUI 메뉴에서 `⌘I`를 단 항목이 정확히 하나인지 — 소스를 직접 훑는다.
    /// 메뉴 항목의 단축키는 런타임에 열거할 방법이 없어(앱을 띄우지 않는다) 소스가 유일한 근거다.
    func testMenuSources_haveExactlyOneCommandIShortcut() throws {
        let sources = ProjectManifest.repositoryRoot.appendingPathComponent("src")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))

        var occurrences: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // SwiftUI 메뉴
                if trimmed.contains(#".keyboardShortcut("i""#) {
                    occurrences.append("\(fileURL.lastPathComponent): \(trimmed)")
                }
                // AppKit 컨텍스트 메뉴
                if trimmed.contains(#"key: "i""#) {
                    occurrences.append("\(fileURL.lastPathComponent): \(trimmed)")
                }
            }
        }

        XCTAssertEqual(
            occurrences.count, 2,
            "⌘I 등록 지점은 메뉴바 1개 + 컨텍스트 메뉴 1개여야 한다: \(occurrences)"
        )
        XCTAssertTrue(
            occurrences.allSatisfy { $0.hasPrefix("AppCommands.swift") || $0.hasPrefix("FileListBridge.swift") },
            "예상 밖 파일이 ⌘I를 등록했다: \(occurrences)"
        )
    }

    /// `Show in Finder` 버튼에 단축키가 되살아나지 않았는지 (메뉴바).
    func testAppCommands_showInFinderHasNoKeyboardShortcut() throws {
        let source = ProjectManifest.repositoryRoot
            .appendingPathComponent("src/App/AppCommands.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)

        let index = try XCTUnwrap(
            lines.firstIndex { $0.contains(#"Button("Show in Finder")"#) },
            "메뉴바에서 Show in Finder 항목이 사라졌다 — 항목은 유지하기로 했다(B9 승계)"
        )
        let following = lines[index..<min(index + 3, lines.count)].joined(separator: "\n")
        XCTAssertFalse(
            following.contains("keyboardShortcut"),
            "Show in Finder에 단축키가 되살아났다 — ⌘I 소유자는 Get Info 하나뿐이다"
        )
    }
}
