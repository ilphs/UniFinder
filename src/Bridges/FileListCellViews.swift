import AppKit

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
        label.font = .systemFont(ofSize: 13)
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
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

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
        label.font = .systemFont(ofSize: 12)
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
        label.font = .systemFont(ofSize: 13)
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
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
/// 아이콘은 라벨과 **같은 계열**(11pt semibold, `secondaryLabelColor`)로 맞춰 톤이 튀지 않게 한다.
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
        label.font = .systemFont(ofSize: 11, weight: .semibold)
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
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 13),
            symbolView.heightAnchor.constraint(equalToConstant: 13),

            label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
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
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
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
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.stringValue = "Loading…"

        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
