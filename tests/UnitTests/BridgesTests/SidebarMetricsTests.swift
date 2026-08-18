import AppKit
import XCTest
@testable import UniFinder

/// 사이드바 치수 계약 (2026-08-18 사용자 요청들이 쌓인 최종 상태).
///
/// **두 축이 서로 다른 방향으로 확정돼 있으니 섞지 말 것**:
/// - **폰트/심볼 크기**는 헤더가 폴더 행보다 **크다**(macOS 관례와 반대, Win10 탐색기 지향 — 사용자
///   확정, 되돌리지 말 것).
/// - **행 높이**는 반대로 헤더/폴더/placeholder **구분 없이 전부 같다**("헤더, 항목 구분없이
///   항목과 동일한 높이로" — 26 → 30 → 60pt를 오가다 최종적으로 `nodeRowHeight` 하나로 합쳐짐).
///   즉 헤더 글자·아이콘은 크게 보이되, 행 자체의 세로 공간(간격)은 폴더 행과 똑같다.
///
/// **이 테스트가 잡으려는 결함 두 가지**
/// 1. 잘림 — 폰트/아이콘만 키우고 행 높이를 그대로 두면 셀 위아래가 잘린다. 픽셀을 봐야 아는
///    결함이라 "행 높이가 콘텐츠를 담기에 충분한가"를 산술로 단언한다.
/// 2. 의도 역전 — 위 두 축의 방향이 바뀌면(헤더가 폴더보다 작아지거나, 행 높이가 다시 갈리면)
///    요청이 조용히 무효화되므로 관계/동일성으로 못박는다.
@MainActor
final class SidebarMetricsTests: TempDirectoryTestCase {

    private var retainedViews: [NSView] = []
    /// 셀의 `window`는 뷰 계층에서 파생될 뿐 강한 참조가 아니다 — 놓으면 편집 진입이 실패로 뒤집힌다.
    private var retainedWindows: [NSWindow] = []

    private func makeDefaults() -> UserDefaults {
        let name = "com.unifinder.tests.sidebarmetrics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeEmptySettings() -> AppSettings {
        let settings = AppSettings(defaults: makeDefaults())
        for url in settings.favoriteURLs { settings.removeFavorite(url) }
        return settings
    }

    private func makeCoordinator() -> SidebarTreeBridge.Coordinator {
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: makeEmptySettings())
        let bridge = SidebarTreeBridge(
            model: model,
            revision: model.revision,
            focusBroker: FocusBroker(),
            onSelect: { _ in },
            onRefresh: {}
        )
        return bridge.makeCoordinator()
    }

    // MARK: - 확정된 치수 (사용자 요청 값)

    func testSidebarMetrics_matchRequestedSizes() {
        XCTAssertEqual(SidebarMetrics.sectionFontSize, 15)
        XCTAssertEqual(SidebarMetrics.sectionSymbolLength, 17)
        XCTAssertEqual(SidebarMetrics.sectionSymbolPointSize, 15)
        XCTAssertEqual(SidebarMetrics.nodeFontSize, 13)
        XCTAssertEqual(SidebarMetrics.nodeIconLength, 16)
    }

    /// **확대 대상은 헤더뿐**이다 (2026-08-18 사용자 확정: "Favorites/Home/Volumes 자체의 아이콘과
    /// 문자열"). macOS 표준 사이드바는 헤더를 항목보다 작게 그리지만 이 앱은 Win10 탐색기를 지향하고
    /// 사용자가 헤더 강조를 명시적으로 요구했다 — 이 관계가 뒤집히면 요청이 무효화된 것이다.
    func testSectionHeader_standsOutAboveFolderRow() {
        XCTAssertGreaterThan(
            SidebarMetrics.sectionFontSize,
            SidebarMetrics.nodeFontSize,
            "섹션 헤더가 폴더 행보다 크지 않다 — 헤더를 키워 달라는 요청이 되돌려졌다"
        )
        XCTAssertGreaterThan(
            SidebarMetrics.sectionSymbolLength,
            SidebarMetrics.nodeIconLength,
            "헤더 심볼이 폴더 아이콘보다 크지 않다 — 헤더 아이콘 강조가 사라졌다"
        )
    }

    /// 폴더 행은 우측 파일 목록과 **완전히 같은 크기**여야 한다 (사용자 확정: "하위 폴더는
    /// 오른쪽창과 동일한 크기"). 숫자를 양쪽에 따로 적으면 조용히 어긋나므로 상수 동일성으로 고정한다.
    func testFolderRow_matchesFileListPaneExactly() {
        XCTAssertEqual(SidebarMetrics.nodeFontSize, FileListMetrics.nameFontSize, "폴더 행 글자 크기가 목록과 다르다")
        XCTAssertEqual(SidebarMetrics.nodeIconLength, FileListMetrics.iconLength, "폴더 아이콘 크기가 목록과 다르다")
        XCTAssertEqual(SidebarMetrics.nodeRowHeight, FileListMetrics.rowHeight, "폴더 행 높이가 목록과 다르다")
        XCTAssertEqual(FileListMetrics.rowHeight, 22, "목록 행 높이(UI설계 §4.1)가 바뀌었다")
        XCTAssertEqual(
            SidebarMetrics.placeholderFontSize,
            FileListMetrics.secondaryFontSize,
            "'Loading…' placeholder가 목록 보조 텍스트와 다른 크기다"
        )
    }

    /// 심볼 렌더 크기가 프레임을 넘으면 헤더 아이콘이 잘린다.
    func testSectionSymbol_fitsInsideItsFrame() {
        XCTAssertLessThanOrEqual(SidebarMetrics.sectionSymbolPointSize, SidebarMetrics.sectionSymbolLength)
    }

    // MARK: - 행 높이 수용성 (잘림 방지)

    func testSectionRowHeight_containsSymbolAndText() {
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.sectionRowHeight,
            SidebarMetrics.sectionSymbolLength,
            "헤더 행이 심볼을 담지 못한다"
        )
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.sectionRowHeight,
            SidebarMetrics.lineHeight(of: SidebarMetrics.sectionFont),
            "헤더 행이 텍스트 라인 높이를 담지 못한다 — 글자 위아래가 잘린다"
        )
    }

    /// 폴더 행 높이는 우측 목록에 묶여 있어(22pt) 여백을 마음대로 못 늘린다 —
    /// 그 안에 아이콘(16)과 13pt/12pt 텍스트가 **실제로 들어가는지**가 유일한 안전장치다.
    func testNodeRowHeight_containsIconAndText() {
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.nodeRowHeight,
            SidebarMetrics.nodeIconLength,
            "폴더 행이 아이콘을 담지 못한다"
        )
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.nodeRowHeight,
            SidebarMetrics.lineHeight(of: SidebarMetrics.nodeFont),
            "폴더 행이 텍스트 라인 높이를 담지 못한다 — 글자 위아래가 잘린다"
        )
        // placeholder("Loading…")도 같은 높이의 행에 그려진다.
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.nodeRowHeight,
            SidebarMetrics.lineHeight(of: SidebarMetrics.placeholderFont),
            "placeholder 행이 'Loading…' 텍스트를 담지 못한다"
        )
        XCTAssertEqual(SidebarMetrics.nodeRowHeight, SidebarMetrics.nodeContentHeight + 6, accuracy: 0.5)
    }

    /// 확정된 값 자체를 못박는다 (2026-08-18 최종 요청 — "헤더, 항목 구분없이 항목과 동일한
    /// 높이로"): 헤더 행 높이가 폴더 행과 **정확히 같다**(22pt). 예전엔 헤더가 폴더보다 높아야
    /// "그룹 경계로 읽힌다"는 반대 방향 요구가 있었지만, 지금은 이 요청으로 뒤집혔다 —
    /// 헤더를 다시 키우는 회귀 금지.
    func testSectionRowHeight_equalsFolderRowHeight() {
        XCTAssertEqual(SidebarMetrics.sectionRowHeight, SidebarMetrics.nodeRowHeight)
        XCTAssertEqual(SidebarMetrics.sectionRowHeight, 22, accuracy: 0.5)
    }

    // MARK: - 브릿지 결선

    /// **항목 종류·위치와 무관하게 언제나 같은 높이를 돌려주는지** (2026-08-18 최종 요청 —
    /// "헤더, 항목 구분없이 항목과 동일한 높이로"). 예전엔 이 함수가 `node.kind`로 분기해
    /// 헤더/폴더에 다른 값을 줬는데(그 전엔 "바로 위 행이 뭐냐"로도 한 번 더 분기했었다),
    /// 지금은 분기 자체가 없다 — `item`이 섹션이든 폴더든 `TreeNode`가 아닌 임의 객체든
    /// 항상 `SidebarMetrics.nodeRowHeight` 하나를 돌려준다.
    func testCoordinatorRowHeight_sameForAllItemKinds() throws {
        let coordinator = makeCoordinator()
        let model = coordinator.parent.model

        let section = try XCTUnwrap(model.sections.first)
        XCTAssertEqual(coordinator.rowHeight(for: section), SidebarMetrics.nodeRowHeight)

        let homeRoot = try XCTUnwrap(model.node(for: testRoot))
        XCTAssertEqual(coordinator.rowHeight(for: homeRoot), SidebarMetrics.nodeRowHeight)

        // TreeNode가 아닌 항목이 와도 같은 높이로 안전하게 떨어진다.
        XCTAssertEqual(coordinator.rowHeight(for: NSObject()), SidebarMetrics.nodeRowHeight)
    }

    /// 위 계약을 상수가 아니라 **실제로 배치된 `NSOutlineView`**에서 재확인한다 — 헤더 행과
    /// 항목 행이 화면에서도 같은 픽셀 높이로 그려지는지.
    func testOutlineView_headerAndItemRowsRenderSameHeight() throws {
        let coordinator = makeCoordinator()
        let bridge = coordinator.parent
        let model = bridge.model

        let outlineView = KeyRoutingOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        retainedViews.append(outlineView)
        outlineView.rowSizeStyle = .custom
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        coordinator.outlineView = outlineView
        outlineView.reloadData()
        for section in model.sections {
            outlineView.expandItem(section)
        }

        XCTAssertGreaterThan(outlineView.numberOfRows, 1, "헤더/항목이 섞인 여러 행이 있어야 의미 있는 테스트다")
        let heights = (0..<outlineView.numberOfRows).map { outlineView.rect(ofRow: $0).height }
        XCTAssertEqual(
            Set(heights.map { ($0 * 2).rounded() }).count,
            1,
            "헤더 행과 항목 행의 렌더 높이가 서로 다르다 — \(heights)"
        )
    }

    /// **헤더 확대가 실제로 화면에 나오게 만드는 핵심 조건** (2026-08-18 실측으로 밝혀냄).
    ///
    /// 섹션을 그룹 행(`isGroupItem == true`)으로 선언하면 `style = .sourceList`의 AppKit이
    /// 셀의 텍스트 폰트와 심볼 크기를 **표준 사이드바 헤더 크기로 강제**한다. 그러면
    /// `SidebarMetrics.sectionFontSize`를 아무리 키워도(24pt까지 실험) 화면은 그대로다.
    /// 이 단언이 무너지면 헤더 확대 요구가 조용히 무효화된다 —
    /// **단위 테스트로는 폰트 값이 정상으로 보이기 때문에** 이 조건 자체를 지키는 수밖에 없다.
    func testSections_areNotGroupRows_soHeaderFontSurvives() throws {
        let coordinator = makeCoordinator()
        let model = coordinator.parent.model
        let outline = KeyRoutingOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        retainedViews.append(outline)

        let section = try XCTUnwrap(model.sections.first)
        XCTAssertFalse(
            coordinator.outlineView(outline, isGroupItem: section),
            "섹션이 그룹 행으로 선언됐다 — AppKit이 헤더 폰트/심볼을 표준 크기로 덮어써 확대가 무효화된다"
        )

        // 섹션이 그룹 행이 아니어도 선택은 여전히 막혀 있어야 한다(그룹 행이 아니라 이쪽이 보장한다).
        XCTAssertFalse(coordinator.outlineView(outline, shouldSelectItem: section))
    }

    /// `rowSizeStyle`이 `.custom`이 아니면 AppKit이 델리게이트 높이를 **무시**해서
    /// 셀만 커지고 행은 그대로인 잘림 상태가 된다.
    func testOutlineView_usesCustomRowSizeStyleAndDelegateHeight() throws {
        let coordinator = makeCoordinator()
        let bridge = coordinator.parent

        let outlineView = KeyRoutingOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        retainedViews.append(outlineView)
        outlineView.rowSizeStyle = .custom
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        coordinator.outlineView = outlineView
        outlineView.reloadData()
        for section in bridge.model.sections {
            outlineView.expandItem(section)
        }

        XCTAssertGreaterThan(outlineView.numberOfRows, 0)
        for row in 0..<outlineView.numberOfRows {
            let item = try XCTUnwrap(outlineView.item(atRow: row))
            XCTAssertEqual(
                outlineView.rect(ofRow: row).height,
                coordinator.rowHeight(for: item),
                accuracy: 0.5,
                "행 \(row)의 실제 높이가 델리게이트 값과 다르다 — 셀 내용이 잘린다"
            )
        }
    }

    // MARK: - 셀 레이아웃 실측

    /// 셀을 실제로 배치했을 때 아이콘/텍스트가 행 높이 안에 들어오는지 (Auto Layout 실측).
    func testTreeNodeCell_layoutFitsWithinRowHeight() throws {
        let cell = TreeNodeCellView(frame: NSRect(x: 0, y: 0, width: 260, height: SidebarMetrics.nodeRowHeight))
        retainedViews.append(cell)

        let node = TreeNode(kind: .folder, url: testRoot, name: "Documents", isSymlink: false, parent: nil)
        let icon = NSImage(size: NSSize(width: SidebarMetrics.nodeIconLength, height: SidebarMetrics.nodeIconLength))
        cell.configure(node: node, folderIcon: icon)
        cell.layoutSubtreeIfNeeded()

        let imageFrame = try XCTUnwrap(cell.imageView?.frame)
        let textFrame = try XCTUnwrap(cell.textField?.frame)

        XCTAssertEqual(imageFrame.height, SidebarMetrics.nodeIconLength, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(imageFrame.minY, 0, "아이콘이 행 위로 삐져나갔다")
        XCTAssertLessThanOrEqual(imageFrame.maxY, cell.bounds.height + 0.5, "아이콘이 행 아래로 잘린다")
        XCTAssertGreaterThanOrEqual(
            textFrame.height,
            SidebarMetrics.lineHeight(of: SidebarMetrics.nodeFont) - 0.5,
            "라벨 높이가 폰트 라인 높이보다 작다 — 글자가 잘린다"
        )
        XCTAssertLessThanOrEqual(textFrame.maxY, cell.bounds.height + 0.5, "라벨이 행 아래로 잘린다")
        // 아이콘과 텍스트가 겹치면 이름 앞글자가 아이콘에 먹힌다.
        XCTAssertGreaterThanOrEqual(textFrame.minX, imageFrame.maxX, "아이콘과 라벨이 겹친다")
        XCTAssertLessThanOrEqual(textFrame.maxX, cell.bounds.width + 0.5, "라벨이 셀 오른쪽을 넘어간다")
    }

    func testTreeSectionCell_layoutFitsWithinRowHeight() throws {
        let cell = TreeSectionCellView(frame: NSRect(x: 0, y: 0, width: 260, height: SidebarMetrics.sectionRowHeight))
        retainedViews.append(cell)

        cell.configure(title: "Favorites", symbolName: "star")
        cell.layoutSubtreeIfNeeded()

        let symbolView = try XCTUnwrap(cell.imageView)
        let symbolFrame = symbolView.frame
        let textFrame = try XCTUnwrap(cell.textField?.frame)

        // SF Symbol을 담은 `NSImageView`는 **0이 아닌 `alignmentRectInsets`**(위/아래 여백)를 갖는다.
        // 프레임에는 그 여백이 포함돼 실제 글리프 상자보다 크므로, 크기·잘림 판정은 **정렬 사각형**으로
        // 해야 한다. 프레임 기준으로 단언하면 눈에 보이는 심볼은 멀쩡한데도 "잘렸다"고 오탐한다
        // (헤더 15pt에서 프레임이 행보다 2pt 큰데 글리프는 행 안에 여유 있게 들어온다).
        let symbolBox = symbolView.alignmentRect(forFrame: symbolFrame)
        XCTAssertEqual(symbolBox.height, SidebarMetrics.sectionSymbolLength, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(symbolBox.minY, 0, "헤더 심볼이 행 위로 삐져나갔다")
        XCTAssertLessThanOrEqual(symbolBox.maxY, cell.bounds.height + 0.5, "헤더 심볼이 행 아래로 잘린다")
        XCTAssertGreaterThanOrEqual(
            textFrame.height,
            SidebarMetrics.lineHeight(of: SidebarMetrics.sectionFont) - 0.5,
            "헤더 라벨 높이가 폰트 라인 높이보다 작다"
        )
        XCTAssertLessThanOrEqual(textFrame.maxY, cell.bounds.height + 0.5, "헤더 라벨이 행 아래로 잘린다")
        XCTAssertGreaterThanOrEqual(textFrame.minX, symbolFrame.maxX, "헤더 심볼과 라벨이 겹친다")
    }

    /// 인라인 rename은 같은 `NSTextField`를 편집 모드로 전환한다 —
    /// 편집 진입 전후로 폰트가 달라지면 글자 크기가 튄다.
    func testTreeNodeCell_renameKeepsSameFont() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // 윈도우는 **닫지 않고 강한 참조로 붙잡는다** — `isReleasedWhenClosed` 기본값(true) 때문에
        // `close()`를 부르면 ARC 해제와 겹쳐 이중 해제로 테스트 프로세스가 죽는다
        // (RenameEntryFailureTests가 같은 이유로 `retainedWindows`를 쓴다).
        retainedWindows.append(window)
        let cell = TreeNodeCellView(frame: NSRect(x: 0, y: 0, width: 260, height: SidebarMetrics.nodeRowHeight))
        retainedViews.append(cell)
        window.contentView?.addSubview(cell)

        let node = TreeNode(kind: .folder, url: testRoot, name: "Documents", isSymlink: false, parent: nil)
        cell.configure(
            node: node,
            folderIcon: NSImage(size: NSSize(
                width: SidebarMetrics.nodeIconLength,
                height: SidebarMetrics.nodeIconLength
            ))
        )

        let before = try XCTUnwrap(cell.textField?.font)
        XCTAssertEqual(before.pointSize, SidebarMetrics.nodeFontSize)

        XCTAssertTrue(cell.beginRename())
        let during = try XCTUnwrap(cell.textField?.font)
        XCTAssertEqual(
            during.pointSize,
            SidebarMetrics.nodeFontSize,
            "rename 진입 시 폰트 크기가 바뀌면 글자가 튀거나 잘린다"
        )

        cell.nameEditor.cancelEditing()
        let after = try XCTUnwrap(cell.textField?.font)
        XCTAssertEqual(after.pointSize, SidebarMetrics.nodeFontSize)

        // 편집 필드가 행 높이 안에 들어오는지 — 편집 중 테두리가 생겨도 잘리면 안 된다.
        cell.layoutSubtreeIfNeeded()
        let textFrame = try XCTUnwrap(cell.textField?.frame)
        XCTAssertLessThanOrEqual(textFrame.height, cell.bounds.height + 0.5, "편집 필드가 행보다 크다")
    }

    /// 상수뿐 아니라 **실제로 배치된 셀**이 좌우 같은 크기로 그려지는지 —
    /// 사용자가 보는 것은 상수가 아니라 렌더 결과다("하위 폴더는 오른쪽창과 동일한 크기").
    func testFolderCellAndListCell_renderIdenticalSizes() throws {
        let listCell = FileNameCellView(
            frame: NSRect(x: 0, y: 0, width: 300, height: FileListMetrics.rowHeight)
        )
        retainedViews.append(listCell)
        listCell.configure(
            with: FileItem(
                url: testRoot.appendingPathComponent("a.txt"),
                name: "a.txt",
                isDirectory: false,
                isHidden: false,
                isSymlink: false,
                size: 0,
                modifiedAt: Date(),
                typeDescription: "Text"
            ),
            iconProvider: IconProvider { _ in nil }
        )
        listCell.layoutSubtreeIfNeeded()

        let treeCell = TreeNodeCellView(
            frame: NSRect(x: 0, y: 0, width: 300, height: SidebarMetrics.nodeRowHeight)
        )
        retainedViews.append(treeCell)
        let node = TreeNode(kind: .folder, url: testRoot, name: "a", isSymlink: false, parent: nil)
        treeCell.configure(
            node: node,
            folderIcon: NSImage(size: NSSize(
                width: SidebarMetrics.nodeIconLength,
                height: SidebarMetrics.nodeIconLength
            ))
        )
        treeCell.layoutSubtreeIfNeeded()

        // 목록 쪽 절대값도 함께 못박는다 — 양쪽이 "같이" 커지는 회귀는 동일성 단언만으로는 못 잡는다.
        XCTAssertEqual(try XCTUnwrap(listCell.textField?.font).pointSize, 13, "목록 셀 폰트(UI설계 §4.1)가 바뀌었다")
        XCTAssertEqual(try XCTUnwrap(listCell.imageView?.frame).height, 16, accuracy: 0.5, "목록 아이콘 크기가 바뀌었다")

        XCTAssertEqual(
            try XCTUnwrap(treeCell.textField?.font).pointSize,
            try XCTUnwrap(listCell.textField?.font).pointSize,
            "트리 폴더 행과 목록 행의 글자 크기가 다르다"
        )
        XCTAssertEqual(
            try XCTUnwrap(treeCell.imageView?.frame).height,
            try XCTUnwrap(listCell.imageView?.frame).height,
            accuracy: 0.5,
            "트리 폴더 아이콘과 목록 아이콘 크기가 다르다"
        )
        XCTAssertEqual(treeCell.bounds.height, listCell.bounds.height, accuracy: 0.5, "행 높이가 다르다")
    }
}
