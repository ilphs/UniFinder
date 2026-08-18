import AppKit
import XCTest
@testable import UniFinder

/// 사이드바 확대(2026-08-18 사용자 요청) — 치수 계약 + 행 높이 수용성.
///
/// **이 테스트가 잡으려는 결함**: 폰트/아이콘만 키우고 행 높이를 그대로 두면 셀 위아래가 잘린다.
/// 잘림 자체는 픽셀을 봐야 알 수 있으므로, "행 높이가 콘텐츠를 담기에 충분한가"를 산술로 단언한다.
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
        XCTAssertEqual(SidebarMetrics.sectionFontSize, 13)
        XCTAssertEqual(SidebarMetrics.sectionSymbolLength, 15)
        XCTAssertEqual(SidebarMetrics.sectionSymbolPointSize, 13)
        XCTAssertEqual(SidebarMetrics.nodeFontSize, 15)
        XCTAssertEqual(SidebarMetrics.nodeIconLength, 18)
    }

    /// 헤더가 항목보다 **작아야** 그룹 헤더로 읽힌다 (사용자 요청의 유일한 위계 제약).
    func testSectionHeader_staysSmallerThanFolderRow() {
        XCTAssertLessThan(
            SidebarMetrics.sectionFontSize,
            SidebarMetrics.nodeFontSize,
            "섹션 헤더가 폴더 행보다 작지 않으면 그룹 헤더로 보이지 않는다"
        )
        XCTAssertLessThan(
            SidebarMetrics.sectionSymbolLength,
            SidebarMetrics.nodeIconLength,
            "헤더 심볼이 폴더 아이콘보다 커지면 위계가 뒤집힌다"
        )
    }

    /// 심볼 렌더 크기가 프레임을 넘으면 헤더 아이콘이 잘린다.
    func testSectionSymbol_fitsInsideItsFrame() {
        XCTAssertLessThanOrEqual(SidebarMetrics.sectionSymbolPointSize, SidebarMetrics.sectionSymbolLength)
    }

    // MARK: - 행 높이 수용성 (잘림 방지)

    func testSectionRowHeight_containsSymbolAndText() {
        let padding = SidebarMetrics.sectionVerticalPadding * 2
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.sectionRowHeight,
            SidebarMetrics.sectionSymbolLength + padding,
            "헤더 행이 심볼 + 여백을 담지 못한다"
        )
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.sectionRowHeight,
            SidebarMetrics.lineHeight(of: SidebarMetrics.sectionFont) + padding,
            "헤더 행이 텍스트 라인 높이 + 여백을 담지 못한다 — 글자 위아래가 잘린다"
        )
    }

    func testNodeRowHeight_containsIconAndText() {
        let padding = SidebarMetrics.nodeVerticalPadding * 2
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.nodeRowHeight,
            SidebarMetrics.nodeIconLength + padding,
            "폴더 행이 아이콘 + 여백을 담지 못한다"
        )
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.nodeRowHeight,
            SidebarMetrics.lineHeight(of: SidebarMetrics.nodeFont) + padding,
            "폴더 행이 텍스트 라인 높이 + 여백을 담지 못한다 — 글자 위아래가 잘린다"
        )
        // placeholder("Loading…")도 같은 높이의 행에 그려진다.
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.nodeRowHeight,
            SidebarMetrics.lineHeight(of: SidebarMetrics.placeholderFont) + padding,
            "placeholder 행이 'Loading…' 텍스트를 담지 못한다"
        )
    }

    /// 확대 **이전** 사이드바는 `rowSizeStyle = .default`로 행 간격이 32pt였다(실행 화면 실측).
    /// 행 높이를 직접 정하면서 이 값보다 좁히면 글자만 커지고 줄 간격은 좁아져 더 답답해진다 —
    /// "읽기 불편하다"는 원래 요청과 정반대가 되므로 회귀로 잡는다.
    static let legacyDefaultRowHeight: CGFloat = 32

    func testRowHeights_notTighterThanLegacyDefault() {
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.nodeRowHeight,
            Self.legacyDefaultRowHeight,
            "폴더 행이 확대 전보다 좁아졌다 — 글자만 커지고 줄 간격이 답답해진다"
        )
        XCTAssertGreaterThanOrEqual(
            SidebarMetrics.sectionRowHeight,
            Self.legacyDefaultRowHeight,
            "섹션 헤더 행이 확대 전보다 좁아졌다"
        )
    }

    // MARK: - 브릿지 결선

    /// 항목 종류별로 다른 높이를 돌려주는지 (헤더/폴더가 같은 높이로 뭉개지면 위계가 사라진다).
    func testCoordinatorRowHeight_branchesByItemKind() throws {
        let coordinator = makeCoordinator()
        let model = coordinator.parent.model

        let section = try XCTUnwrap(model.sections.first)
        XCTAssertEqual(coordinator.rowHeight(for: section), SidebarMetrics.sectionRowHeight)

        let homeRoot = try XCTUnwrap(model.node(for: testRoot))
        XCTAssertEqual(coordinator.rowHeight(for: homeRoot), SidebarMetrics.nodeRowHeight)

        // TreeNode가 아닌 항목이 와도 폴더 행 높이로 안전하게 떨어진다.
        XCTAssertEqual(coordinator.rowHeight(for: NSObject()), SidebarMetrics.nodeRowHeight)
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

        // SF Symbol을 담은 `NSImageView`는 **0이 아닌 `alignmentRectInsets`**(위/아래 여백)를 갖는다 —
        // Auto Layout 제약은 프레임이 아니라 정렬 사각형에 걸리므로, 크기 계약은 그쪽으로 확인한다.
        // (프레임 높이로 단언하면 심볼 폰트 메트릭에 따라 흔들린다)
        XCTAssertEqual(
            symbolView.alignmentRect(forFrame: symbolFrame).height,
            SidebarMetrics.sectionSymbolLength,
            accuracy: 0.5
        )
        XCTAssertGreaterThanOrEqual(symbolFrame.minY, 0, "헤더 심볼이 행 위로 삐져나갔다")
        XCTAssertLessThanOrEqual(symbolFrame.maxY, cell.bounds.height + 0.5, "헤더 심볼이 행 아래로 잘린다")
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
        cell.configure(node: node, folderIcon: NSImage(size: NSSize(width: 18, height: 18)))

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

    /// 우측 파일 목록은 이번 확대 대상이 아니다 — 사이드바 상수가 목록 셀로 새지 않았는지 지킨다.
    func testFileListCells_keepOriginalSizes() throws {
        let cell = FileNameCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        retainedViews.append(cell)
        cell.configure(
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
        cell.layoutSubtreeIfNeeded()

        XCTAssertEqual(try XCTUnwrap(cell.textField?.font).pointSize, 13, "목록 셀 폰트가 사이드바 확대에 휩쓸렸다")
        XCTAssertEqual(try XCTUnwrap(cell.imageView?.frame).height, 16, accuracy: 0.5, "목록 아이콘이 사이드바 확대에 휩쓸렸다")
    }
}
