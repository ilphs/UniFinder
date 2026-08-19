import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// Open With 서브메뉴 (후속 T4 / UI설계 §6 · D5).
///
/// 검증하는 계약 3가지:
/// 1. 파일에만 활성이다(폴더가 섞이면 대상이 정의되지 않는다)
/// 2. 서브메뉴는 **열릴 때** 채워진다(우클릭 응답을 LaunchServices 조회로 늦추지 않는다)
/// 3. 고른 앱으로 여는 것은 **이번 한 번**이다(기본 앱을 바꾸지 않는다)
@MainActor
final class OpenWithMenuTests: XCTestCase {

    private var retainedViews: [NSView] = []
    private var retainedWindows: [NSWindow] = []

    private func makeItem(name: String, isDirectory: Bool = false) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/open-with").appendingPathComponent(name, isDirectory: isDirectory),
            name: name,
            isDirectory: isDirectory,
            isHidden: false,
            isSymlink: false,
            size: isDirectory ? nil : 12,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 0),
            typeDescription: isDirectory ? "Folder" : "Document"
        )
    }

    /// LaunchServices에 붙지 않는 가짜 후보 조회원.
    private func makeService(
        candidates: [URL] = [],
        defaultApplication: URL? = nil,
        opened: OpenRecorder? = nil
    ) -> OpenWithService {
        OpenWithService(
            candidatesProvider: { _ in candidates },
            defaultApplicationProvider: { _ in defaultApplication },
            displayNameProvider: { $0.deletingPathExtension().lastPathComponent },
            contentTypeProvider: { _ in nil },
            launcher: { files, application, completion in
                opened?.record(files: files, application: application)
                completion(nil)
            },
            fileDefaultSetter: { _, _ in XCTFail("메뉴 경로가 기본 앱을 바꾸면 안 된다") },
            contentTypeDefaultSetter: { _, _ in XCTFail("메뉴 경로가 시스템 기본값을 바꾸면 안 된다") }
        )
    }

    final class OpenRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [([URL], URL)] = []
        func record(files: [URL], application: URL) {
            lock.lock(); defer { lock.unlock() }
            calls.append((files, application))
        }
        var all: [(files: [URL], application: URL)] {
            lock.lock(); defer { lock.unlock() }
            return calls.map { (files: $0.0, application: $0.1) }
        }
    }

    /// 실행 결과(completion handler)는 임의 스레드에서 오므로 기록도 스레드 안전해야 한다.
    final class MessageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private func makeCoordinator(
        items: [FileItem],
        selectedRows: IndexSet = [],
        service: OpenWithService? = nil,
        onOpenWith: @escaping ([URL], URL) -> Void = { _, _ in },
        onOpenWithOther: @escaping ([URL]) -> Void = { _ in }
    ) -> FileListBridge.Coordinator {
        var selection = Set<URL>()
        var bridge = FileListBridge(
            items: items,
            revision: 1,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "OpenWith-\(UUID().uuidString)")!),
            onOpen: { _ in },
            onNavigateUp: {},
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: { _ in }
        )
        bridge.openWithService = service ?? makeService()
        bridge.onOpenWith = onOpenWith
        bridge.onOpenWithOther = onOpenWithOther

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

    // MARK: - 존재·활성 조건

    func testItemMenu_file_hasEnabledOpenWithSubmenu() {
        let coordinator = makeCoordinator(items: [makeItem(name: "a.txt")], selectedRows: IndexSet(integer: 0))

        let menu = coordinator.makeContextMenu(forRow: 0)
        let item = menu.items.first { $0.title == "Open With" }

        XCTAssertNotNil(item, "파일 컨텍스트 메뉴에 'Open With'가 없다")
        XCTAssertEqual(item?.isEnabled, true)
        XCTAssertNotNil(item?.submenu, "서브메뉴가 없으면 후보를 고를 수 없다")
    }

    func testItemMenu_folder_disablesOpenWith() {
        let coordinator = makeCoordinator(
            items: [makeItem(name: "docs", isDirectory: true)],
            selectedRows: IndexSet(integer: 0)
        )

        let menu = coordinator.makeContextMenu(forRow: 0)
        let item = menu.items.first { $0.title == "Open With" }

        XCTAssertEqual(item?.isEnabled, false, "폴더를 다른 앱으로 여는 것은 이 앱의 범위가 아니다")
    }

    /// 다중 선택에 폴더가 섞이면 "무엇을 어디로"가 정의되지 않는다.
    func testItemMenu_mixedSelectionWithFolder_disablesOpenWith() {
        let items = [makeItem(name: "a.txt"), makeItem(name: "docs", isDirectory: true)]
        let coordinator = makeCoordinator(items: items, selectedRows: IndexSet([0, 1]))

        let menu = coordinator.makeContextMenu(forRow: 0)
        let item = menu.items.first { $0.title == "Open With" }

        XCTAssertEqual(item?.isEnabled, false)
    }

    // MARK: - 지연 구성 (D5)

    /// 메뉴를 만드는 시점에는 서브메뉴가 **비어 있어야** 한다 — 그래야 우클릭이 즉시 뜬다.
    func testSubmenu_isEmptyUntilOpened() {
        let application = URL(fileURLWithPath: "/Applications/Preview.app")
        let coordinator = makeCoordinator(
            items: [makeItem(name: "a.pdf")],
            selectedRows: IndexSet(integer: 0),
            service: makeService(candidates: [application], defaultApplication: application)
        )

        let menu = coordinator.makeContextMenu(forRow: 0)
        let submenu = menu.items.first { $0.title == "Open With" }?.submenu

        XCTAssertEqual(submenu?.items.count, 0, "우클릭 시점에 LaunchServices를 조회하면 메뉴가 늦게 뜬다")

        coordinator.menuNeedsUpdate(submenu!)
        XCTAssertGreaterThan(submenu!.items.count, 0, "열릴 때는 채워져야 한다")
    }

    func testSubmenu_listsDefaultFirstThenCandidatesThenOther() {
        let preview = URL(fileURLWithPath: "/Applications/Preview.app")
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        let coordinator = makeCoordinator(
            items: [makeItem(name: "a.pdf")],
            selectedRows: IndexSet(integer: 0),
            // 기본 앱이 후보 목록에도 들어 있는 실제 상황 — 중복으로 두 번 뜨면 안 된다.
            service: makeService(candidates: [preview, xcode], defaultApplication: preview)
        )

        let submenu = coordinator.makeContextMenu(forRow: 0).items.first { $0.title == "Open With" }?.submenu
        coordinator.menuNeedsUpdate(submenu!)

        XCTAssertEqual(
            submenu!.items.map(\.title),
            ["Preview (default)", "Xcode", "", "Other…"],
            "기본 앱 → 후보 → 구분선 → Other… 순서여야 한다(구분선의 title은 빈 문자열)"
        )
    }

    func testSubmenu_noCandidates_showsDisabledPlaceholder() {
        let coordinator = makeCoordinator(items: [makeItem(name: "a.bin")], selectedRows: IndexSet(integer: 0))

        let submenu = coordinator.makeContextMenu(forRow: 0).items.first { $0.title == "Open With" }?.submenu
        coordinator.menuNeedsUpdate(submenu!)

        let placeholder = submenu!.items.first
        XCTAssertEqual(placeholder?.title, "No Applications Available")
        XCTAssertEqual(placeholder?.isEnabled, false)
        XCTAssertTrue(submenu!.items.contains { $0.title == "Other…" }, "후보가 없어도 직접 고를 길은 남긴다")
    }

    // MARK: - 실행

    func testSubmenu_selectingApplication_invokesCallbackWithFileAndApplication() {
        let file = makeItem(name: "a.pdf")
        let preview = URL(fileURLWithPath: "/Applications/Preview.app")
        var calls: [([URL], URL)] = []
        let coordinator = makeCoordinator(
            items: [file],
            selectedRows: IndexSet(integer: 0),
            service: makeService(candidates: [preview]),
            onOpenWith: { calls.append(($0, $1)) }
        )

        let submenu = coordinator.makeContextMenu(forRow: 0).items.first { $0.title == "Open With" }?.submenu
        coordinator.menuNeedsUpdate(submenu!)
        let item = submenu!.items.first { $0.title == "Preview" }
        _ = item?.target?.perform(item?.action, with: item)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0.map(\.path), [file.url.path])
        XCTAssertEqual(calls.first?.1, preview)
    }

    // MARK: - 선택 전체를 연다 (reviewer minor #6)

    /// **활성 판정 범위 = 실행 범위**. 예전에는 판정만 선택 전체를 보고 실행은 우클릭한 1개였다 —
    /// 3개를 골라 Open With를 눌러도 1개만 열렸다(Finder는 3개를 연다).
    func testSubmenu_selectingApplication_opensEverySelectedFile() {
        let files = [makeItem(name: "a.pdf"), makeItem(name: "b.pdf"), makeItem(name: "c.pdf")]
        let preview = URL(fileURLWithPath: "/Applications/Preview.app")
        var calls: [([URL], URL)] = []
        let coordinator = makeCoordinator(
            items: files,
            selectedRows: IndexSet([0, 1, 2]),
            service: makeService(candidates: [preview]),
            onOpenWith: { calls.append(($0, $1)) }
        )

        // 우클릭한 행은 첫 번째지만, 선택은 셋이다.
        let submenu = coordinator.makeContextMenu(forRow: 0).items.first { $0.title == "Open With" }?.submenu
        coordinator.menuNeedsUpdate(submenu!)
        let item = submenu!.items.first { $0.title == "Preview" }
        _ = item?.target?.perform(item?.action, with: item)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls.first?.0.map(\.lastPathComponent), ["a.pdf", "b.pdf", "c.pdf"],
            "3개를 선택하고 Open With를 눌렀는데 전부 열리지 않았다"
        )
    }

    /// `Other…`도 같은 규칙이다 — 앱을 직접 고르는 경로에서만 대상이 1개로 줄면 안 된다.
    func testSubmenu_other_passesEverySelectedFile() {
        let files = [makeItem(name: "a.pdf"), makeItem(name: "b.pdf")]
        var chosen: [[URL]] = []
        let coordinator = makeCoordinator(
            items: files,
            selectedRows: IndexSet([0, 1]),
            onOpenWithOther: { chosen.append($0) }
        )

        let submenu = coordinator.makeContextMenu(forRow: 0).items.first { $0.title == "Open With" }?.submenu
        coordinator.menuNeedsUpdate(submenu!)
        let item = submenu!.items.first { $0.title == "Other…" }
        _ = item?.target?.perform(item?.action, with: item)

        XCTAssertEqual(chosen.map { $0.map(\.lastPathComponent) }, [["a.pdf", "b.pdf"]])
    }

    /// 폴더가 섞이면 대상이 정의되지 않으므로 **실행 자체가 막힌다**(비활성 판정과 같은 근거).
    func testSubmenu_mixedSelectionWithFolder_hasNoTargets() {
        let items = [makeItem(name: "a.txt"), makeItem(name: "docs", isDirectory: true)]
        var calls: [([URL], URL)] = []
        let coordinator = makeCoordinator(
            items: items,
            selectedRows: IndexSet([0, 1]),
            service: makeService(candidates: [URL(fileURLWithPath: "/Applications/Preview.app")]),
            onOpenWith: { calls.append(($0, $1)) }
        )

        let submenu = coordinator.makeContextMenu(forRow: 0).items.first { $0.title == "Open With" }?.submenu
        coordinator.menuNeedsUpdate(submenu!)

        XCTAssertTrue(coordinator.openWithTargets.isEmpty, "폴더가 섞였는데 실행 대상이 남아 있다")
        XCTAssertEqual(submenu!.items.count, 0, "대상이 없으면 후보를 채우지 않는다")
        XCTAssertTrue(calls.isEmpty)
    }

    func testSubmenu_other_invokesChooserCallback() {
        let file = makeItem(name: "a.pdf")
        var chosen: [[URL]] = []
        let coordinator = makeCoordinator(
            items: [file],
            selectedRows: IndexSet(integer: 0),
            onOpenWithOther: { chosen.append($0) }
        )

        let submenu = coordinator.makeContextMenu(forRow: 0).items.first { $0.title == "Open With" }?.submenu
        coordinator.menuNeedsUpdate(submenu!)
        let item = submenu!.items.first { $0.title == "Other…" }
        _ = item?.target?.perform(item?.action, with: item)

        XCTAssertEqual(chosen.map { $0.map(\.path) }, [[file.url.path]])
    }

    /// **메뉴에서 고르는 것은 이번 한 번뿐**이다 — 기본 앱 지정은 Get Info 창만 한다(UI설계 §6).
    func testService_openDoesNotChangeDefaultApplication() {
        let recorder = OpenRecorder()
        let service = makeService(candidates: [], opened: recorder)
        let file = URL(fileURLWithPath: "/tmp/open-with/a.pdf")
        let preview = URL(fileURLWithPath: "/Applications/Preview.app")

        service.open([file], with: preview)

        XCTAssertEqual(recorder.all.count, 1)
        XCTAssertEqual(recorder.all.first?.application, preview)
        // 기본 앱 setter는 `makeService`에서 `XCTFail`로 막아 두었다 — 불렸다면 이 테스트가 실패한다.
    }

    /// 빈 목록으로는 **아무것도 실행하지 않는다**(대상 없는 실행은 조용한 오작동의 씨앗이다).
    func testService_openWithEmptySelectionDoesNothing() {
        let recorder = OpenRecorder()
        let service = makeService(candidates: [], opened: recorder)

        service.open([], with: URL(fileURLWithPath: "/Applications/Preview.app"))

        XCTAssertTrue(recorder.all.isEmpty)
    }

    // MARK: - 실행 실패 전달 (reviewer minor #7)

    /// `NSWorkspace.open`의 실패는 completion handler로만 온다 — 예전에는 `nil`을 넘겨 삼켰다.
    /// 서비스는 그 사유를 호출자에게 **그대로** 넘겨야 한다(호출자가 상태바에 띄운다).
    func testService_openPropagatesLauncherFailure() {
        struct LaunchFailure: LocalizedError { var errorDescription: String? { "app is damaged" } }
        let service = OpenWithService(
            candidatesProvider: { _ in [] },
            defaultApplicationProvider: { _ in nil },
            contentTypeProvider: { _ in nil },
            launcher: { _, _, completion in completion(LaunchFailure()) },
            fileDefaultSetter: { _, _ in },
            contentTypeDefaultSetter: { _, _ in }
        )
        let received = MessageBox()

        service.open([URL(fileURLWithPath: "/tmp/a.pdf")], with: URL(fileURLWithPath: "/Applications/Preview.app")) { error in
            received.append(error?.localizedDescription ?? "success")
        }

        XCTAssertEqual(received.all, ["app is damaged"])
    }

    /// 사용자에게 보이는 문구가 **무엇이·어디로·왜** 실패했는지 말하는지.
    func testFailureMessage_namesSubjectApplicationAndReason() {
        struct LaunchFailure: LocalizedError { var errorDescription: String? { "app is damaged" } }
        let preview = URL(fileURLWithPath: "/Applications/Preview.app")

        let single = AppModel.openWithFailureMessage(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.pdf")],
            application: preview,
            error: LaunchFailure()
        )
        XCTAssertTrue(single.contains("a.pdf"), single)
        XCTAssertTrue(single.contains("Preview"), single)
        XCTAssertTrue(single.contains("app is damaged"), single)

        let many = AppModel.openWithFailureMessage(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")],
            application: preview,
            error: LaunchFailure()
        )
        XCTAssertTrue(many.contains("2 items"), "여러 개일 때 개수를 말하지 않는다: \(many)")
    }

    /// 사이드바 트리 메뉴는 이번 개정에서 바뀌지 않는다(트리는 폴더만 다룬다).
    func testTreeMenu_isUnchanged() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "OpenWith-Tree-\(UUID().uuidString)")!)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: FileManager.default.temporaryDirectory, settings: settings)
        let bridge = SidebarTreeBridge(
            model: model,
            revision: model.revision,
            focusBroker: FocusBroker(),
            onSelect: { _ in },
            onRefresh: {}
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
        for section in model.sections { outlineView.expandItem(section) }

        for row in 0..<outlineView.numberOfRows {
            guard let menu = coordinator.makeContextMenu(forRow: row) else { continue }
            XCTAssertFalse(menu.items.contains { $0.title == "Open With" }, "트리 메뉴에 Open With가 들어갔다")
            XCTAssertFalse(menu.items.contains { $0.title == "Get Info" }, "트리 메뉴에 Get Info가 들어갔다")
        }
    }
}
