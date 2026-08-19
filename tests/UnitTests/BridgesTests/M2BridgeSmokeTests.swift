import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// M2의 **브릿지/셀 계층** 수용 기준 스모크 테스트 (ralph 작성).
///
/// 서비스·ViewModel 계층은 `FileOperationsTests`/`ClipboardModelTests`/`TreeModelInvalidationTests`가
/// 담당하므로 여기서는 그쪽에서 닿을 수 없는 것만 확인한다:
/// - T4/B6: 클립보드 상태만 바뀌었을 때 `reloadData` 판정
/// - T4: 숨김 × cut 알파 합성 규칙
/// - T5/B7: 셀 재사용 시 편집 상태 리셋, 다중 선택 F2 무동작
/// - T7: 컨텍스트 메뉴 구성·활성 조건
@MainActor
final class M2BridgeSmokeTests: XCTestCase {

    /// `Coordinator.tableView`는 weak라서 테스트가 강한 참조를 들고 있어야 한다
    /// (지역 변수만 두면 함수 반환과 함께 해제될 수 있다).
    private var retainedTableViews: [KeyRoutingTableView] = []

    /// 셀을 담을 윈도우. **인라인 편집은 셀이 윈도우에 붙어 있어야만 시작된다**
    /// (`InlineNameEditor.begin`의 `field.window == nil` 가드 — M2 백로그).
    /// 윈도우 없이 만든 목록에서 "편집 진입 성공"을 기대하면 브릿지의 진입 실패 보고 결함을
    /// 테스트가 그대로 눈감아 준다.
    private var retainedWindows: [NSWindow] = []

    // MARK: - 헬퍼

    private func makeItem(name: String, isDirectory: Bool = false, isHidden: Bool = false) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/m2-smoke").appendingPathComponent(name, isDirectory: isDirectory),
            name: name,
            isDirectory: isDirectory,
            isHidden: isHidden,
            isSymlink: false,
            size: 10,
            modifiedAt: Fixture.fixedDate(),
            typeDescription: "파일"
        )
    }

    private func makeBridge(
        items: [FileItem],
        cutURLs: Set<URL> = [],
        clipboardRevision: Int = 0,
        canPaste: Bool = false,
        onOpen: @escaping ([FileItem]) -> Void = { _ in },
        onBeginRename: @escaping (URL) -> Void = { _ in },
        onDelete: @escaping () -> Void = {},
        isFavorite: @escaping (URL) -> Bool = { _ in false }
    ) -> FileListBridge {
        var selection = Set<URL>()
        return FileListBridge(
            items: items,
            revision: 1,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            cutURLs: cutURLs,
            clipboardRevision: clipboardRevision,
            canPaste: canPaste,
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "M2BridgeSmoke-\(UUID().uuidString)")!),
            onOpen: onOpen,
            onNavigateUp: {},
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: { _ in },
            onDelete: onDelete,
            isFavorite: isFavorite,
            onBeginRename: onBeginRename
        )
    }

    private func makeCoordinator(
        items: [FileItem],
        selectedRows: IndexSet = [],
        cutURLs: Set<URL> = [],
        canPaste: Bool = false,
        onOpen: @escaping ([FileItem]) -> Void = { _ in },
        onBeginRename: @escaping (URL) -> Void = { _ in },
        onDelete: @escaping () -> Void = {},
        isFavorite: @escaping (URL) -> Bool = { _ in false }
    ) -> FileListBridge.Coordinator {
        let bridge = makeBridge(
            items: items,
            cutURLs: cutURLs,
            canPaste: canPaste,
            onOpen: onOpen,
            onBeginRename: onBeginRename,
            onDelete: onDelete,
            isFavorite: isFavorite
        )
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        retainedTableViews.append(tableView)
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
        coordinator.updateCutKeys(cutURLs)
        tableView.reloadData()
        if !selectedRows.isEmpty {
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        }
        return coordinator
    }

    private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    // MARK: - T4 / architect B6 — 클립보드 상태 변경이 화면에 반영되는가

    func testReloadReason_clipboardRevisionChangedAlone_stillTriggersReload() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 7,
            revision: 7,
            appliedItemCount: 3,
            itemCount: 3,
            appliedClipboardRevision: 1,
            clipboardRevision: 2
        )
        XCTAssertEqual(
            reason, .clipboardChanged,
            "클립보드만 바뀌어도 reloadData가 필요하다 — 이 판정이 없으면 cut 표시가 영영 안 그려진다(B6)"
        )
    }

    func testReloadReason_nothingChanged_doesNotReload() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 7,
            revision: 7,
            appliedItemCount: 3,
            itemCount: 3,
            appliedClipboardRevision: 2,
            clipboardRevision: 2
        )
        XCTAssertEqual(reason, .none)
    }

    func testReloadReason_directoryRevisionWins_overClipboard() {
        let reason = FileListBridge.Coordinator.reloadReason(
            appliedRevision: 7,
            revision: 8,
            appliedItemCount: 3,
            itemCount: 3,
            appliedClipboardRevision: 1,
            clipboardRevision: 2
        )
        XCTAssertEqual(reason, .directoryChanged)
    }

    func testCoordinator_cutKeysUseNormalizedPaths_soTrailingSlashDoesNotBreakMatching() {
        let folder = makeItem(name: "folder", isDirectory: true)
        let coordinator = makeCoordinator(items: [folder])

        // 클립보드 쪽 URL에는 후행 슬래시가 없다(파스트보드/조작 결과 표기).
        let withoutSlash = URL(fileURLWithPath: folder.url.path)
        coordinator.updateCutKeys([withoutSlash])

        XCTAssertTrue(
            coordinator.cutKeys.contains(PathKey.key(folder.url)),
            "폴더 URL의 후행 슬래시 표기 차이로 cut 표시가 어긋나면 안 된다(T4 URL 표기 정합 규칙)"
        )
    }

    // MARK: - T4 — 숨김 × cut 알파 합성 (UI설계 §4.2)

    func testNameCell_alphaComposition_hiddenTimesCut() {
        let cell = FileNameCellView(frame: .zero)
        let provider = IconProvider { _ in nil }

        cell.configure(with: makeItem(name: "a.txt"), iconProvider: provider, isCut: false)
        XCTAssertEqual(cell.alphaValue, 1.0, accuracy: 0.001)

        cell.configure(with: makeItem(name: "b.txt", isHidden: true), iconProvider: provider, isCut: false)
        XCTAssertEqual(cell.alphaValue, 0.4, accuracy: 0.001, "숨김 항목은 40%")

        cell.configure(with: makeItem(name: "c.txt"), iconProvider: provider, isCut: true)
        XCTAssertEqual(cell.alphaValue, 0.5, accuracy: 0.001, "잘라내기 항목은 50%")

        cell.configure(with: makeItem(name: "d.txt", isHidden: true), iconProvider: provider, isCut: true)
        XCTAssertEqual(cell.alphaValue, 0.2, accuracy: 0.001, "숨김 × cut = 곱연산 0.2")
    }

    // MARK: - T5 / architect B7 — 셀 재사용 시 편집 상태 리셋

    /// 스크롤 중 편집을 시작한 셀이 다른 행으로 재사용되면, 편집은 폐기되고
    /// 새 항목이 편집 상태를 물려받지 않아야 한다(잘못된 대상 rename 방지).
    func testNameCell_reconfiguringForAnotherItem_discardsInProgressEditing() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let cell = FileNameCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        window.contentView?.addSubview(cell)

        let provider = IconProvider { _ in nil }
        let original = makeItem(name: "original.txt")
        cell.configure(with: original, iconProvider: provider)

        var committed: [(URL, String)] = []
        cell.nameEditor.onCommit = { url, name in committed.append((url, name)) }

        cell.beginRename()
        XCTAssertTrue(cell.nameEditor.isEditing, "편집이 시작되지 않아 재사용 시나리오를 검증할 수 없음")
        XCTAssertEqual(cell.nameEditor.target, original.url)

        // 스크롤로 이 셀이 다른 행에 재사용되는 상황
        let recycled = makeItem(name: "recycled.txt")
        cell.configure(with: recycled, iconProvider: provider, isCut: false)

        XCTAssertFalse(cell.nameEditor.isEditing, "셀 재사용 후에도 편집 상태가 남아 있으면 엉뚱한 행이 편집된다")
        XCTAssertNil(cell.nameEditor.target)
        XCTAssertTrue(committed.isEmpty, "재사용에 의한 폐기는 커밋을 유발하면 안 된다")
        XCTAssertEqual(cell.textField?.stringValue, "recycled.txt")
    }

    func testNameCell_prepareForReuse_alsoResetsEditing() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let cell = FileNameCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        window.contentView?.addSubview(cell)
        cell.configure(with: makeItem(name: "a.txt"), iconProvider: IconProvider { _ in nil })
        cell.beginRename()

        cell.prepareForReuse()

        XCTAssertFalse(cell.nameEditor.isEditing)
    }

    // MARK: - T5 — 다중 선택 시 F2 무동작

    func testF2_withMultipleSelection_doesNotBeginRename() {
        var requested: [URL] = []
        let items = [makeItem(name: "a.txt"), makeItem(name: "b.txt")]
        let coordinator = makeCoordinator(
            items: items,
            selectedRows: IndexSet([0, 1]),
            onBeginRename: { requested.append($0) }
        )

        let handled = coordinator.handleKeyDown(keyEvent(String(KeyScalar.f2), modifiers: [.function]))

        XCTAssertTrue(handled, "F2는 브릿지가 소비해야 한다(비프음 방지)")
        XCTAssertTrue(requested.isEmpty, "다중 선택 시 F2는 무동작이어야 한다(UI설계 §6)")
    }

    func testF2_withSingleSelection_beginsRenameForThatItem() {
        var requested: [URL] = []
        let items = [makeItem(name: "a.txt"), makeItem(name: "b.txt")]
        let coordinator = makeCoordinator(
            items: items,
            selectedRows: IndexSet(integer: 1),
            onBeginRename: { requested.append($0) }
        )

        _ = coordinator.handleKeyDown(keyEvent(String(KeyScalar.f2), modifiers: [.function]))

        XCTAssertEqual(requested, [items[1].url])
    }

    func testF2_withCapsLockOn_stillBeginsRename() {
        // Caps Lock은 토글 상태라 모든 keyDown에 붙는다 — 걸러내지 않으면 F2가 죽는다(M2 리뷰 major).
        var requested: [URL] = []
        let items = [makeItem(name: "a.txt")]
        let coordinator = makeCoordinator(
            items: items,
            selectedRows: IndexSet(integer: 0),
            onBeginRename: { requested.append($0) }
        )

        let handled = coordinator.handleKeyDown(
            keyEvent(String(KeyScalar.f2), modifiers: [.function, .capsLock])
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(requested, [items[0].url], "Caps Lock 상태에서 F2가 무동작이면 안 된다")
    }

    func testEnter_withCapsLockOn_stillOpensSelection() {
        var opened: [FileItem] = []
        let items = [makeItem(name: "a.txt")]
        let coordinator = makeCoordinator(items: items, selectedRows: IndexSet(integer: 0), onOpen: { opened = $0 })

        let handled = coordinator.handleKeyDown(keyEvent("\r", modifiers: [.capsLock]))

        XCTAssertTrue(handled)
        XCTAssertEqual(opened.map(\.name), ["a.txt"], "Caps Lock 상태에서 Enter(열기)가 죽으면 안 된다")
    }

    // MARK: - T6 / M2 리뷰 major — 새 폴더 생성 직후 rename 토큰 조기 소비

    /// `createFolder` 완료 → `reload(selecting:)`이 items를 비우고 비동기 로드를 시작한다.
    /// 그 직후 도착한 rename 요청은 목록에 대상이 없어 진입에 실패하는데, 예전 코드는 토큰을
    /// **먼저** 소비해서 로드 완료 후 재시도가 불가능했다 — "생성 후 즉시 rename 진입"이 사실상 항상 실패.
    func testRenameRequest_whenItemNotLoadedYet_keepsTokenAndSucceedsAfterItemsArrive() {
        let created = makeItem(name: "새 폴더", isDirectory: true)
        let coordinator = makeCoordinator(items: [])
        let request = AppModel.RenameRequest(url: created.url, token: 1)

        // 1) 로드 전 — 목록이 비어 있어 진입 실패
        XCTAssertTrue(coordinator.scheduleRenameIfNeeded(request))
        XCTAssertFalse(coordinator.applyRenameRequest(request), "빈 목록에서 편집에 진입할 수는 없다")
        XCTAssertNotEqual(
            coordinator.appliedRenameToken, request.token,
            "실패한 요청이 소비되면 로드 완료 후 재시도 기회가 사라진다(T6 수용 기준)"
        )

        // 2) 로드 완료 — 같은 요청이 다시 예약되고 이번엔 성공해야 한다
        coordinator.items = [created]
        coordinator.tableView?.reloadData()
        XCTAssertTrue(coordinator.scheduleRenameIfNeeded(request), "소비되지 않은 토큰은 다시 예약되어야 한다")
        XCTAssertTrue(coordinator.applyRenameRequest(request), "항목이 도착한 뒤에는 편집에 진입해야 한다")
        XCTAssertEqual(coordinator.appliedRenameToken, request.token)
    }

    func testRenameRequest_afterSuccessfulEntry_isNotRepeated() {
        let item = makeItem(name: "a.txt")
        let coordinator = makeCoordinator(items: [item])
        let request = AppModel.RenameRequest(url: item.url, token: 3)

        XCTAssertTrue(coordinator.scheduleRenameIfNeeded(request))
        XCTAssertTrue(coordinator.applyRenameRequest(request))

        XCTAssertFalse(coordinator.scheduleRenameIfNeeded(request), "성공한 요청은 1회성이어야 한다(재진입 금지)")
    }

    func testRenameRequest_whileScheduled_isNotScheduledTwice() {
        let item = makeItem(name: "a.txt")
        let coordinator = makeCoordinator(items: [item])
        let request = AppModel.RenameRequest(url: item.url, token: 5)

        XCTAssertTrue(coordinator.scheduleRenameIfNeeded(request))
        XCTAssertFalse(
            coordinator.scheduleRenameIfNeeded(request),
            "예약된 요청이 updateNSView마다 중복 예약되면 안 된다"
        )
    }

    /// 목록에 영영 나타나지 않는 대상(숨김 설정 등)에 대한 무한 재시도 방지 상한.
    func testRenameRequest_neverAppearingTarget_givesUpAfterAttemptCap() {
        let coordinator = makeCoordinator(items: [])
        let request = AppModel.RenameRequest(url: URL(fileURLWithPath: "/tmp/m2-smoke/ghost"), token: 9)

        for _ in 0..<FileListBridge.Coordinator.maxRenameAttempts {
            _ = coordinator.scheduleRenameIfNeeded(request)
            XCTAssertFalse(coordinator.applyRenameRequest(request))
        }

        XCTAssertFalse(coordinator.scheduleRenameIfNeeded(request), "상한을 넘으면 재시도를 포기해야 한다")
    }

    // MARK: - T7 — 컨텍스트 메뉴 (UI설계 §6)

    func testItemContextMenu_matchesSpecOrderAndDisablesRenameOnMultipleSelection() {
        let items = [makeItem(name: "a.txt"), makeItem(name: "b.txt")]
        let coordinator = makeCoordinator(items: items, selectedRows: IndexSet([0, 1]))

        let menu = coordinator.makeContextMenu(forRow: 0)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(
            titles,
            // UI설계 §6 개정판 (2026-08-19, 후속 T4·T5) — 그룹이 "연다 / 바꾼다 / 본다 / 등록한다"로 재편됐다.
            // - "Open in New Window"는 다중 창 T7에서 추가 (OpenInNewWindowMenuTests)
            // - "Open With"는 후속 T4에서 추가 (OpenWithMenuTests)
            // - "Get Info"는 후속 T5에서 추가, `Cmd+I`의 유일한 소유자다 (GetInfoWindowTests)
            [
                "Open", "Open in New Window", "Open With",
                "Copy", "Cut", "Rename", "Move to Trash",
                "Get Info", "Show in Finder",
                "Add to Favorites",
            ]
        )

        let rename = menu.items.first { $0.title == "Rename" }
        XCTAssertEqual(rename?.isEnabled, false, "다중 선택 시 이름 변경은 비활성이어야 함(UI설계 §6)")

        let info = menu.items.first { $0.title == "Get Info" }
        XCTAssertEqual(info?.isEnabled, false, "다중 선택 시 Get Info는 비활성이어야 함(D2 — Rename과 같은 규칙)")
    }

    // MARK: - 즐겨찾기 토글 (2026-08-18)

    /// 파일에는 즐겨찾기 항목이 비활성이어야 한다(폴더만 즐겨찾기가 된다).
    func testItemContextMenu_file_disablesFavoriteToggle() {
        let coordinator = makeCoordinator(items: [makeItem(name: "a.txt")], selectedRows: IndexSet(integer: 0))

        let menu = coordinator.makeContextMenu(forRow: 0)
        let favorite = menu.items.first { $0.title.hasSuffix("Favorites") }

        XCTAssertEqual(favorite?.title, "Add to Favorites")
        XCTAssertEqual(favorite?.isEnabled, false, "파일에 즐겨찾기 등록이 열려 있다")
    }

    func testItemContextMenu_folder_enablesFavoriteToggle() {
        let items = [makeItem(name: "docs", isDirectory: true)]
        let coordinator = makeCoordinator(items: items, selectedRows: IndexSet(integer: 0))

        let menu = coordinator.makeContextMenu(forRow: 0)
        let favorite = menu.items.first { $0.title.hasSuffix("Favorites") }

        XCTAssertEqual(favorite?.title, "Add to Favorites")
        XCTAssertEqual(favorite?.isEnabled, true)
    }

    /// 이미 등록된 폴더면 **해제 항목 하나로 토글**된다(등록/해제를 둘 다 띄우지 않는다).
    func testItemContextMenu_registeredFolder_showsRemoveInsteadOfAdd() {
        let items = [makeItem(name: "docs", isDirectory: true)]
        let coordinator = makeCoordinator(
            items: items,
            selectedRows: IndexSet(integer: 0),
            isFavorite: { _ in true }
        )

        let menu = coordinator.makeContextMenu(forRow: 0)
        let favoriteItems = menu.items.filter { $0.title.hasSuffix("Favorites") }

        XCTAssertEqual(favoriteItems.map(\.title), ["Remove from Favorites"], "등록/해제가 동시에 노출됐다")
    }

    func testItemContextMenu_singleSelection_enablesRename() {
        let items = [makeItem(name: "a.txt")]
        let coordinator = makeCoordinator(items: items, selectedRows: IndexSet(integer: 0))

        let menu = coordinator.makeContextMenu(forRow: 0)
        XCTAssertEqual(menu.items.first { $0.title == "Rename" }?.isEnabled, true)
    }

    func testBackgroundContextMenu_disablesPasteWhenClipboardEmpty() {
        let coordinator = makeCoordinator(items: [], canPaste: false)

        let menu = coordinator.makeContextMenu(forRow: -1)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["New Folder", "Paste", "Sort By", "Refresh"])
        XCTAssertEqual(menu.items.first { $0.title == "Paste" }?.isEnabled, false)
    }

    func testBackgroundContextMenu_enablesPasteWhenClipboardHasItems() {
        let coordinator = makeCoordinator(items: [], canPaste: true)
        let menu = coordinator.makeContextMenu(forRow: -1)
        XCTAssertEqual(menu.items.first { $0.title == "Paste" }?.isEnabled, true)
    }

    func testBackgroundContextMenu_sortSubmenuChecksCurrentDescriptor() {
        let coordinator = makeCoordinator(items: [])
        let menu = coordinator.makeContextMenu(forRow: -1)

        guard let submenu = menu.items.first(where: { $0.title == "Sort By" })?.submenu else {
            return XCTFail("정렬 기준 서브메뉴가 없음")
        }
        XCTAssertEqual(submenu.items.first { $0.title == "Name" }?.state, .on, "현재 정렬 기준에 체크 표시(UI설계 §6)")
        XCTAssertEqual(submenu.items.first { $0.title == "Ascending" }?.state, .on)
        XCTAssertEqual(submenu.items.first { $0.title == "Descending" }?.state, .off)
    }

    /// 컨텍스트 메뉴 액션과 단축키 액션이 같은 콜백을 쓰는지 (T7 — 중복 구현 금지).
    func testContextMenuDelete_andCommandBackspace_useSameCallback() {
        var deleteCount = 0
        let items = [makeItem(name: "a.txt")]
        let coordinator = makeCoordinator(
            items: items,
            selectedRows: IndexSet(integer: 0),
            onDelete: { deleteCount += 1 }
        )

        _ = coordinator.handleKeyDown(keyEvent(String(KeyScalar.backspace), modifiers: [.command]))
        XCTAssertEqual(deleteCount, 1)

        let menu = coordinator.makeContextMenu(forRow: 0)
        guard let item = menu.items.first(where: { $0.title == "Move to Trash" }),
              let action = item.action
        else { return XCTFail("휴지통으로 이동 메뉴 항목이 없음") }
        _ = item.target?.perform(action, with: item)

        XCTAssertEqual(deleteCount, 2, "메뉴와 단축키가 같은 코드 경로를 써야 한다")
    }
}
