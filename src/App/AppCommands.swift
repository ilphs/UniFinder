import SwiftUI

/// 앱 레벨 단축키 (T7 / architect B4).
///
/// **경계**: 방향키·`Enter`·타입-어헤드 등 목록/트리 내부 원시 `keyDown`은
/// `FileListBridge`/`SidebarTreeBridge`의 Coordinator가 소유한다. 여기서는 수식키가 붙은
/// 앱 레벨 단축키만 등록하며, 브릿지가 포커스를 가진 상태에서 충돌하면 브릿지가 우선한다.
///
/// **텍스트 편집과의 공존 (m2-impl T2)**: 메뉴 key equivalent는 responder chain보다 먼저
/// 잡히므로, 표준 "편집" 메뉴(`.pasteboard` 그룹)는 **그대로 두고** 파일 조작을 별도 메뉴에
/// 둔다. 게다가 주소창 편집 중·인라인 rename 중에는 아래 항목들을 `.disabled`로 내려
/// `Cmd+C/X/V`가 텍스트 필드의 기본 동작으로 흘러가게 한다.
struct AppCommands: Commands {

    let model: AppModel

    /// 텍스트 편집 중에는 파일 조작 단축키를 통째로 비활성화한다.
    private var isEditingText: Bool { model.isTextEditing }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 폴더") { model.createFolderInCurrentDirectory() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(isEditingText)
        }

        CommandMenu("파일 조작") {
            Button("복사") { model.copy() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(isEditingText || model.directory.selection.isEmpty)

            Button("잘라내기") { model.cut() }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(isEditingText || model.directory.selection.isEmpty)

            Button("붙여넣기") { model.pasteIntoCurrentFolder() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(isEditingText || !model.canPaste)

            Divider()

            Button("이름 변경") { model.beginRenameSelection() }
                .keyboardShortcut(KeyEquivalent(Character(KeyScalar.f2)), modifiers: [])
                .disabled(isEditingText || !model.canRenameSelection)

            Button("휴지통으로 이동") { model.trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(isEditingText || model.directory.selection.isEmpty)

            Divider()

            // architect B9 — Finder 정보창을 여는 공개 API가 없어 "Finder에서 보기"로 대체
            Button("Finder에서 보기") { model.revealInFinder() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(isEditingText || model.directory.selection.isEmpty)
        }

        CommandMenu("이동") {
            Button("뒤로") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.navigation.canGoBack)

            Button("앞으로") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.navigation.canGoForward)

            Button("상위 폴더") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.navigation.canGoUp)

            Divider()

            Button("열기") { model.openSelection() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.directory.selection.isEmpty)

            Button("선택 항목 열기") { model.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.directory.selection.isEmpty)

            Divider()

            Button("위치 입력…") { model.beginAddressEditing() }
                .keyboardShortcut("l", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button(model.settings.showHidden ? "숨김 항목 가리기" : "숨김 항목 표시") {
                model.toggleHiddenItems()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Divider()

            Button("새로 고침") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }

        CommandGroup(replacing: .help) { }
    }
}
