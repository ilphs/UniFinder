import AppKit

/// 우측 파일 목록 치수 (UI설계 §4.1).
///
/// **왜 상수로 빼는가**: 사용자가 사이드바 폴더 행을 "오른쪽 창과 동일한 크기"로 요구했다
/// (2026-08-18). 같은 숫자를 양쪽에 따로 적어 두면 한쪽만 바뀌었을 때 조용히 어긋나므로,
/// `SidebarMetrics`가 이 값을 **직접 참조**해 "동일함"을 컴파일 시점 사실로 만든다.
enum FileListMetrics {

    /// 목록 행 높이. `FileListBridge`가 `tableView.rowHeight`로 그대로 쓴다.
    static let rowHeight: CGFloat = 22
    /// 이름 컬럼 텍스트.
    static let nameFontSize: CGFloat = 13
    /// 이름 컬럼 아이콘 프레임(정사각형).
    static let iconLength: CGFloat = 16
    /// 수정일/종류/크기 등 보조 텍스트. 트리의 "Loading…" placeholder도 같은 계열로 맞춘다.
    static let secondaryFontSize: CGFloat = 12

    static var nameFont: NSFont { .systemFont(ofSize: nameFontSize) }
    static var secondaryFont: NSFont { .systemFont(ofSize: secondaryFontSize) }
}

/// 좌측 사이드바(트리) 전용 치수 (2026-08-18 — 사이드바 확대 요청, 같은 날 2차로 범위 축소).
///
/// **왜 한곳에 모으는가**: 폰트·아이콘 프레임·심볼 pointSize·행 높이는 서로 맞물려 있어서
/// 한 값만 키우면 다른 쪽이 잘린다. 특히 행 높이는 `SidebarTreeBridge`가, 셀 내용은
/// 이 파일이 정하므로 두 파일에 상수를 흩뿌리면 어긋난 채로 조용히 잘리기 쉽다.
///
/// **확대 대상은 섹션 헤더뿐이다** (2026-08-18 사용자 확정):
/// - 헤더(Favorites/Home/Volumes)는 **키운다** — 섹션 구분이 눈에 들어와야 한다는 것이 요청의 핵심이다.
/// - 폴더 행은 **우측 목록과 완전히 같은 크기**로 되돌린다 — 글자·아이콘뿐 아니라 행 높이까지
///   `FileListMetrics`를 그대로 참조한다.
enum SidebarMetrics {

    // MARK: 섹션 헤더 (Favorites / Home / Volumes)

    /// 헤더 텍스트. **폴더 행(`nodeFontSize` = 13)보다 크다.**
    ///
    /// **macOS 관례와 반대라는 점을 알고 그렇게 뒀다.** 표준 사이드바는 그룹 헤더를 항목보다 작게
    /// 그려 배경으로 물러나게 하지만, 이 앱은 Win10 탐색기를 지향하고(같은 파일 `TreeSectionCellView`
    /// 주석 참조 — 헤더에 심볼을 두는 것도 같은 이유) 사용자가 "Favorites/Home/Volumes 자체의
    /// 아이콘과 문자열을 키워 달라"고 명시적으로 요청했다(2026-08-18).
    /// 헤더가 항목보다 커 보이는 것은 **버그가 아니라 확정된 선택**이니 되돌리지 말 것.
    static let sectionFontSize: CGFloat = 15
    /// 헤더 심볼 프레임(정사각형). 폴더 아이콘(`nodeIconLength` = 16)보다 커서 헤더가 먼저 읽힌다.
    static let sectionSymbolLength: CGFloat = 17
    /// 심볼 자체의 렌더 크기(`NSImage.SymbolConfiguration`의 pointSize).
    ///
    /// 프레임(`sectionSymbolLength`)보다 **작아야** 한다 — 같거나 크면 글리프가 프레임에 꽉 차
    /// 라벨보다 무거워 보이고, 확대·축소 여지도 없어진다. 지금은 15/17로 2pt 여백을 둬
    /// 라벨(15pt semibold)과 시각 무게를 맞춘다.
    static let sectionSymbolPointSize: CGFloat = 15
    /// 헤더 앞 여백 / 심볼-라벨 간격 / 꼬리 여백.
    static let sectionLeading: CGFloat = 5
    static let sectionSpacing: CGFloat = 6
    static let sectionTrailing: CGFloat = 4

    // MARK: 폴더 행 — 우측 목록과 **동일**하게 유지 (숫자를 따로 적지 않는다)

    /// 폴더 이름 텍스트. 목록 이름 컬럼과 **같은 값을 참조**한다(따로 적으면 어긋난다).
    static let nodeFontSize: CGFloat = FileListMetrics.nameFontSize
    /// 폴더/볼륨 아이콘 프레임(정사각형). `VolumeIconCache`와 `SidebarTreeBridge.folderIcon`이 만드는
    /// **이미지 크기와 같아야 한다** — 이미지가 더 작으면 `.scaleProportionallyDown`이 확대를 하지
    /// 않아 프레임 안에서 작게 뜬다. (프레임과 이미지가 둘 다 16인 지금은 맞아떨어진 상태이며,
    /// 한쪽만 바꾸는 순간 다시 어긋난다 — 그래서 양쪽이 이 상수를 참조한다.)
    static let nodeIconLength: CGFloat = FileListMetrics.iconLength
    /// 트리는 여기에 계층 들여쓰기가 더 붙으므로 목록(4)보다 앞 여백이 작다.
    static let nodeLeading: CGFloat = 2
    static let nodeSpacing: CGFloat = 6
    static let nodeTrailing: CGFloat = 4

    /// "Loading…" placeholder — 목록의 보조 텍스트와 같은 계열(폴더 행보다 한 단계 작게).
    static let placeholderFontSize: CGFloat = FileListMetrics.secondaryFontSize

    // MARK: 파생 값

    static var sectionFont: NSFont { .systemFont(ofSize: sectionFontSize, weight: .semibold) }
    static var nodeFont: NSFont { .systemFont(ofSize: nodeFontSize) }
    static var placeholderFont: NSFont { .systemFont(ofSize: placeholderFontSize) }

    /// 한 줄 텍스트가 잘리지 않는 최소 높이.
    static func lineHeight(of font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// 폴더/placeholder 행이 담아야 하는 콘텐츠 높이.
    static var nodeContentHeight: CGFloat {
        max(nodeIconLength, lineHeight(of: nodeFont), lineHeight(of: placeholderFont))
    }

    /// 섹션 헤더 행 높이.
    ///
    /// 2026-08-18 "헤더/항목 구분 없이 항목과 동일한 높이로" 요청으로 `nodeRowHeight`를
    /// **그대로 참조**한다 — 예전엔 `sectionContentHeight + sectionVerticalPadding * 2`라는
    /// 별도 공식으로 26 → 30 → 60pt를 오갔는데, 그 공식 자체가 "헤더는 항목과 다른 높이"라는
    /// 전제였다. 지금은 그 전제가 사용자 요청으로 뒤집혔으니 매직 넘버로 다시 맞추는 대신
    /// 원본을 그대로 참조해 폴더 행 높이가 바뀌어도 조용히 어긋나지 않게 한다.
    /// (폰트·심볼 크기는 여전히 헤더가 더 크다 — 그건 별개로 확정된 선택, `sectionFontSize` 참조.)
    static var sectionRowHeight: CGFloat { nodeRowHeight }

    /// 폴더/placeholder 행 높이 — **우측 목록과 같은 값**.
    ///
    /// `rowSizeStyle = .default`(시스템이 정하는 고정 높이)로 두면 헤더가 커진 뒤 잘리고, 반대로
    /// 여기서 임의의 값을 만들면 좌우 pane의 행 리듬이 어긋난다. 그래서 브릿지가
    /// `outlineView(_:heightOfRowByItem:)`으로 이 값을 돌려준다.
    static var nodeRowHeight: CGFloat { FileListMetrics.rowHeight }
}

/// 이름 컬럼 셀 — 16pt 아이콘 + 꼬리 말줄임 텍스트 (UI설계 §4.1).
final class FileNameCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("FileNameCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    /// 인라인 이름 변경기 (m2-impl T5). 셀 1개당 1개를 소유하고 재사용 시 반드시 리셋한다.
    private(set) lazy var nameEditor = InlineNameEditor(field: label)

    /// 셀 재사용 시 이전 아이콘 요청을 취소하기 위한 핸들 (스크롤 성능 보호).
    private var iconToken: IconRequestToken?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FileListMetrics.nameFont
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.allowsDefaultTighteningForTruncation = false
        // 인라인 rename 대상이므로 편집 가능 필드로 만들어 두고, 평상시 외형만 라벨처럼 유지한다
        // (architect B7 — `labelWithString:`으로 만든 필드는 편집으로 전환할 수 없다).
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.isBezeled = false
        label.drawsBackground = false
        label.focusRingType = .none
        label.usesSingleLineMode = true
        label.cell?.isScrollable = true

        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: FileListMetrics.iconLength),
            icon.heightAnchor.constraint(equalToConstant: FileListMetrics.iconLength),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// - Parameter isCut: 잘라내기 대기 중인 항목인지 (UI설계 §4.2 — 50% 불투명).
    func configure(with item: FileItem, iconProvider: IconProvider, isCut: Bool = false) {
        // 셀 재사용 방어 (architect B7): 이 셀이 다른 항목으로 재구성되는 순간
        // 진행 중이던 인라인 편집을 커밋 없이 폐기한다. 리셋을 빠뜨리면 스크롤 중
        // 엉뚱한 행이 편집 상태로 재사용돼 잘못된 대상이 rename된다.
        nameEditor.reset()

        iconToken?.cancel()
        iconToken = nil

        label.stringValue = item.name
        // 숨김(0.4) × cut(0.5) 곱연산 — 동시 적용 시 0.2 (UI설계 §4.2 / m2-impl T4)
        alphaValue = (item.isHidden ? 0.4 : 1.0) * (isCut ? 0.5 : 1.0)
        representedURL = item.url

        if let cached = iconProvider.cachedIcon(for: item) {
            icon.image = cached
        } else {
            icon.image = iconProvider.placeholderIcon(for: item)
            let requestedURL = item.url
            iconToken = iconProvider.icon(for: item) { [weak self] image in
                guard let self, self.representedURL == requestedURL else { return }
                self.icon.image = image
            }
        }
    }

    /// 비동기 아이콘 도착 시 셀이 다른 항목으로 재사용되었는지 확인하기 위한 표식.
    private(set) var representedURL: URL?

    /// 인라인 이름 변경 시작 (F2 / 컨텍스트 메뉴 / 새 폴더 생성 직후).
    ///
    /// - Returns: **실제로** 편집에 진입했으면 `true`.
    ///   `InlineNameEditor.begin`은 셀이 아직 윈도우에 붙기 전이면 조용히 되돌아가므로(`field.window == nil`),
    ///   호출자가 성공을 단정하면 `isRenaming`이 편집 중이 아닌데도 고착되고 rename 토큰이 조기 소비된다
    ///   (M2 백로그 — 재시도 경로가 죽는다).
    @discardableResult
    func beginRename() -> Bool {
        guard let representedURL else { return false }
        nameEditor.begin(target: representedURL)
        return nameEditor.isEditing
    }

    /// `NSTableView`가 셀을 재사용하기 직전에 부른다. `configure`와 이중으로 방어한다.
    override func prepareForReuse() {
        super.prepareForReuse()
        nameEditor.reset()
    }
}

/// 수정일 / 종류 / 크기 컬럼용 단순 텍스트 셀.
final class FileTextCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("FileTextCell")

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FileListMetrics.secondaryFont
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor

        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(text: String, alignment: NSTextAlignment, isHidden: Bool) {
        label.stringValue = text
        label.alignment = alignment
        alphaValue = isHidden ? 0.4 : 1.0
    }
}

/// 트리 노드 셀 — 폴더 아이콘 + 이름.
///
/// 2026-08-18 — 크기는 **우측 목록 셀(`FileNameCellView`)과 동일**하다. 글자·아이콘뿐 아니라
/// 행 높이까지 `FileListMetrics`를 경유해 같은 값을 쓴다(사용자 확정: "하위 폴더는 오른쪽창과
/// 동일한 크기"). 이름 변경 규칙에 이어 **치수도** 목록과 한 몸으로 묶인 셈이다 —
/// 한쪽만 키우고 싶다면 `SidebarMetrics`에서 참조를 끊는 것이 먼저다.
final class TreeNodeCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("TreeNodeCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    /// 트리 노드도 목록과 동일한 인라인 이름 변경 규칙을 쓴다 (m2-impl T5).
    private(set) lazy var nameEditor = InlineNameEditor(field: label)

    private(set) var representedURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown

        label.translatesAutoresizingMaskIntoConstraints = false
        // 인라인 rename은 이 필드를 그대로 편집 모드로 전환하므로(InlineNameEditor) 폰트가 자동으로 따라간다 —
        // 편집기 쪽에 별도 폰트를 두면 rename 진입 순간 글자 크기가 튄다.
        label.font = SidebarMetrics.nodeFont
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.isBezeled = false
        label.drawsBackground = false
        label.focusRingType = .none
        label.usesSingleLineMode = true

        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.nodeLeading),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SidebarMetrics.nodeIconLength),
            icon.heightAnchor.constraint(equalToConstant: SidebarMetrics.nodeIconLength),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: SidebarMetrics.nodeSpacing),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.nodeTrailing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(node: TreeNode, folderIcon: NSImage) {
        // 셀 재사용 방어 (architect B7) — 목록 셀과 동일 규칙
        nameEditor.reset()

        label.stringValue = node.name
        representedURL = node.url
        icon.image = folderIcon
        // 접근 불가 폴더는 회색 처리 (UI설계 §3)
        label.textColor = node.isAccessible ? .labelColor : .tertiaryLabelColor
        alphaValue = node.isSymlink ? 0.9 : 1.0
    }

    /// 목록 셀과 동일 규칙 — 진입 성공 여부를 반드시 돌려준다 (M2 백로그).
    @discardableResult
    func beginRename() -> Bool {
        guard let representedURL else { return false }
        nameEditor.begin(target: representedURL)
        return nameEditor.isEditing
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameEditor.reset()
    }
}

/// 트리 섹션 헤더 셀.
///
/// 2026-08-18 — 아이콘 슬롯 추가. Win10 탐색기의 사이드바 헤더를 지향하므로
/// macOS 표준 사이드바(헤더에 아이콘 없음)와 달리 섹션마다 심볼을 하나 둔다.
/// 아이콘은 라벨과 **같은 계열**(현재 15pt semibold = `SidebarMetrics.sectionSymbolPointSize`,
/// `secondaryLabelColor`)로 맞춰 심볼과 글자가 한 덩어리로 읽히게 한다.
///
/// 2026-08-18(2차) — 헤더 확대. 크기 수치는 전부 `SidebarMetrics`가 소유하므로 여기에 다시 적지 않는다.
/// 헤더 텍스트/심볼은 폴더 행보다 **크다**(15pt vs 13pt, 심볼 17 vs 아이콘 16).
/// macOS 표준(헤더가 항목보다 작음)과 반대지만 의도된 선택이다 —
/// 근거는 `SidebarMetrics.sectionFontSize` 주석 참조(사용자 확정). 되돌리지 말 것.
///
/// **이 셀의 크기가 화면에 반영되려면 섹션이 그룹 행이 아니어야 한다.**
/// 그룹 행이면 AppKit이 여기서 지정한 폰트·심볼을 표준 헤더 크기로 덮어쓴다 —
/// 자세한 근거와 실험 기록은 `SidebarTreeBridge`의 `isGroupItem` 주석에 있다.
final class TreeSectionCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("TreeSectionCell")

    private let label = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()

    /// 마지막으로 적용한 심볼 이름. 셀 재사용 시 같은 심볼을 다시 만들지 않기 위한 가드다
    /// (`NSImage(systemSymbolName:)`는 매 호출마다 새 이미지를 만든다).
    private var appliedSymbolName: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        // 이 폰트가 화면에 그대로 나오려면 이 셀이 **그룹 행이 아니어야** 한다 —
        // `SidebarTreeBridge`의 `isGroupItem` 주석 참조(AppKit이 그룹 행 폰트를 강제로 덮어쓴다).
        label.font = SidebarMetrics.sectionFont
        label.textColor = .secondaryLabelColor

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        // 템플릿 이미지 + tint로 라벨과 같은 색을 쓴다(다크/라이트 자동 대응).
        symbolView.contentTintColor = .secondaryLabelColor

        addSubview(symbolView)
        addSubview(label)
        textField = label
        imageView = symbolView

        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.sectionLeading),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: SidebarMetrics.sectionSymbolLength),
            symbolView.heightAnchor.constraint(equalToConstant: SidebarMetrics.sectionSymbolLength),

            label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: SidebarMetrics.sectionSpacing),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.sectionTrailing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// - Parameter symbolName: SF Symbols 이름. `nil`이면 아이콘 자리를 비운다.
    ///   **섹션 이름 문자열이 아니라 `TreeNode.SectionKind`에서 온 값**이어야 한다(A단계 영어화 대비).
    func configure(title: String, symbolName: String?) {
        label.stringValue = title

        guard appliedSymbolName != symbolName else { return }
        appliedSymbolName = symbolName

        guard let symbolName else {
            symbolView.image = nil
            return
        }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: SidebarMetrics.sectionSymbolPointSize,
            weight: .semibold
        )
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(configuration)
    }
}

/// 트리 placeholder 셀 ("Loading…").
final class TreePlaceholderCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("TreePlaceholderCell")

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        // 폴더 행과 같은 자리·같은 높이(22pt)의 행에 뜨는 보조 문구다.
        // 폴더 행이 우측 목록과 같은 크기로 되돌아갔으므로(2026-08-18) 이것도 목록 보조 텍스트와
        // 같은 계열로 맞춘다 — 폴더 행보다 한 단계 작다.
        label.font = SidebarMetrics.placeholderFont
        label.textColor = .tertiaryLabelColor
        label.stringValue = "Loading…"

        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.nodeLeading),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.nodeTrailing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
