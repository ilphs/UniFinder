import AppKit

/// 셀 안의 `NSTextField`를 인라인 이름 편집기로 전환/복구하는 헬퍼 (m2-impl T5 / architect B7).
///
/// 목록 셀(`FileNameCellView`)과 트리 셀(`TreeNodeCellView`)이 같은 규칙을 공유하도록
/// 편집 상태·검증·커밋/취소 판정을 이 한 곳에 모은다.
///
/// **셀 재사용 안전성이 이 타입의 존재 이유다.** `NSTableView`/`NSOutlineView`는 스크롤 중
/// 셀 뷰를 재사용하므로, 편집 중인 셀이 다른 행으로 재활용되면 **엉뚱한 항목이 rename될 수 있다.**
/// 두 겹으로 막는다:
/// 1. `reset()` — 셀이 다른 항목으로 재구성될 때 진행 중 편집을 커밋 없이 폐기한다
/// 2. `target` 스냅샷 — 커밋 시점의 대상은 셀의 현재 항목이 아니라 **편집을 시작한 항목**이다
@MainActor
final class InlineNameEditor: NSObject, NSTextFieldDelegate {

    /// 편집 중인 대상. 편집 시작 시점에 고정되며 셀 재사용의 영향을 받지 않는다.
    private(set) var target: URL?
    private(set) var isEditing = false

    /// 커밋 직전 검증 (UI설계 §7.2). 거부 사유를 돌려주면 편집을 유지하고 셰이크한다.
    var validate: ((URL, String) -> String?)?
    /// 검증을 통과한 최종 이름.
    var onCommit: ((URL, String) -> Void)?
    /// 커밋/취소/폐기 공통 종료 훅 (`AppModel.isRenaming` 해제용).
    var onEnd: ((URL) -> Void)?

    private weak var field: NSTextField?
    private var originalValue = ""
    /// 재진입 방지 — `abortEditing()`이 다시 `controlTextDidEndEditing`을 부른다.
    private var isTearingDown = false
    private var isCancelling = false

    init(field: NSTextField) {
        self.field = field
        super.init()
    }

    // MARK: - 편집 시작 / 종료

    func begin(target: URL) {
        guard let field, !isEditing else { return }
        self.target = target
        originalValue = field.stringValue
        isEditing = true
        isCancelling = false
        isTearingDown = false

        field.delegate = self
        setEditingAppearance(true)

        guard let window = field.window else {
            // 윈도우에 붙기 전이면 편집을 시작할 수 없다 — 상태를 되돌린다.
            finish(commit: false)
            return
        }
        window.makeFirstResponder(field)
        selectBaseName()
    }

    /// 셀 재사용/폴더 이동 등으로 편집 컨텍스트가 사라질 때 호출한다.
    /// 진행 중 편집은 **커밋하지 않고** 폐기한다(잘못된 대상에 rename이 적용되는 것을 막는다).
    func reset() {
        guard isEditing else {
            setEditingAppearance(false)
            return
        }
        cancelEditing()
    }

    /// `Esc` 또는 컨텍스트 소멸 — 원래 이름으로 되돌리고 편집을 끝낸다.
    func cancelEditing() {
        guard isEditing, !isTearingDown else { return }
        isCancelling = true
        field?.stringValue = originalValue
        _ = field?.abortEditing()
        finish(commit: false)
    }

    private func finish(commit: Bool) {
        guard isEditing else { return }
        isTearingDown = true
        defer { isTearingDown = false }

        let endedTarget = target
        // 편집 중에는 field editor가 최신 텍스트를 들고 있다 — 셀의 `stringValue`보다 우선한다.
        let newName = field?.currentEditor()?.string ?? field?.stringValue ?? originalValue

        isEditing = false
        isCancelling = false
        target = nil
        setEditingAppearance(false)

        // 편집을 끝냈으면 field editor를 놓아준다(테이블이 다시 first responder가 되도록).
        restoreFirstResponderToOwningTable()
        field?.stringValue = commit ? newName : originalValue
        field?.toolTip = nil

        guard let endedTarget else { return }
        if commit, newName != originalValue {
            onCommit?(endedTarget, newName)
        }
        onEnd?(endedTarget)
    }

    /// 편집이 끝나면 first responder를 목록/트리 뷰로 되돌린다.
    ///
    /// 셀 계층은 `NSTextField` → `NSTableCellView` → `NSTableRowView` → `NSTableView`이므로
    /// superview를 한두 단계 올라가는 것으로는 테이블에 닿지 않는다(행 뷰가 잡힌다).
    private func restoreFirstResponderToOwningTable() {
        guard let field, let window = field.window, field.currentEditor() != nil else { return }
        var candidate: NSView? = field.superview
        while let view = candidate, !(view is NSTableView) {
            candidate = view.superview
        }
        window.makeFirstResponder(candidate)
    }

    // MARK: - 외형

    private func setEditingAppearance(_ editing: Bool) {
        guard let field else { return }
        field.isEditable = editing
        field.isSelectable = editing
        field.isBordered = editing
        field.drawsBackground = editing
        field.backgroundColor = editing ? .textBackgroundColor : .clear
        field.bezelStyle = .squareBezel
        field.focusRingType = editing ? .default : .none
        if !editing {
            field.delegate = nil
        }
    }

    /// 확장자를 제외한 이름 부분만 선택한다 (UI설계 §7.2).
    private func selectBaseName() {
        guard let field, let editor = field.currentEditor() else { return }
        let name = field.stringValue as NSString
        let ext = name.pathExtension as NSString
        // 숨김 파일(".gitignore")은 확장자가 아니라 이름 전체로 본다.
        let baseLength: Int
        if ext.length == 0 || (name.hasPrefix(".") && name.deletingPathExtension.isEmpty) {
            baseLength = name.length
        } else {
            baseLength = max(0, name.length - ext.length - 1)
        }
        editor.selectedRange = NSRange(location: 0, length: baseLength)
    }

    /// 검증 실패 표시 — 필드 셰이크 + 툴팁 사유 (UI설계 §7.2).
    private func shake(reason: String) {
        guard let field else { return }
        field.toolTip = reason
        field.wantsLayer = true
        guard let layer = field.layer else { return }

        let animation = CAKeyframeAnimation(keyPath: "position.x")
        let x = layer.position.x
        animation.values = [x, x - 6, x + 6, x - 4, x + 4, x]
        animation.keyTimes = [0, 0.15, 0.35, 0.55, 0.8, 1]
        animation.duration = 0.3
        layer.add(animation, forKey: "unifinder.shake")
        NSSound.beep()
    }

    // MARK: - NSTextFieldDelegate

    /// 편집 종료 직전 검증. `false`를 돌려주면 편집이 유지된다 (UI설계 §7.2 "편집 유지").
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard isEditing, !isCancelling, !isTearingDown, let target else { return true }
        guard let reason = validate?(target, fieldEditor.string) else { return true }
        shake(reason: reason)
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditing, !isTearingDown else { return }
        // 포커스 이탈 = 커밋 (Finder 관례 — UI설계 §7.2 미확정 사항을 m2-impl T5에서 확정)
        finish(commit: !isCancelling)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isEditing else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditing()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // 검증 → 통과 시 커밋. 실패하면 편집 유지.
            if let target, let reason = validate?(target, textView.string) {
                shake(reason: reason)
                return true
            }
            finish(commit: true)
            return true
        default:
            return false
        }
    }
}
