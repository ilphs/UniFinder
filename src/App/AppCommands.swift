import SwiftUI

/// 앱 레벨 단축키 (T7 / architect B4).
///
/// **경계**: 방향키·`Enter`·타입-어헤드 등 목록/트리 내부 원시 `keyDown`은
/// `FileListBridge`/`SidebarTreeBridge`의 Coordinator가 소유한다. 여기서는 수식키가 붙은
/// 앱 레벨 단축키만 등록하며, 브릿지가 포커스를 가진 상태에서 충돌하면 브릿지가 우선한다.
///
/// **메뉴 구성 (2026-08-18 D단계)**: macOS Finder의 구조(File · Edit · View · Go · Window · Help)에
/// 맞춘다. Finder에 없는 `File Actions` 메뉴는 없애고 항목을 File/Edit으로 흩었다.
/// `Go`만 커스텀 `CommandMenu`로 두는데, 커스텀 메뉴는 View와 Window 사이에 들어가므로
/// Finder 순서와 자동으로 일치한다.
///
/// **텍스트 편집과의 공존 (m2-impl T2 → D단계에서 방식 교체)**: 예전에는 표준 Edit 메뉴를
/// 그대로 두고 파일 조작을 별도 메뉴에 둔 뒤, 편집 중에는 그쪽을 `.disabled`로 내려
/// `Cmd+C/X/V`를 텍스트 필드로 흘려보냈다. Edit으로 합치면서 그 회피책을 쓸 수 없게 됐다 —
/// `.disabled`로 내리면 ⌘C를 달고 있는 메뉴 항목이 **하나도 없게 되고**, AppKit은 ⌘ 단축키를
/// responder chain보다 메인 메뉴에서 먼저 찾으므로 주소창·인라인 rename의 복사/붙여넣기가 죽는다.
/// 그래서 Edit의 Cut/Copy/Paste/Select All은 **항상 활성**으로 두고 `AppModel.editActionTarget`이
/// 동작만 분기한다(메뉴 활성 상태는 뷰 갱신 시점 스냅샷이라 first responder 변화를 못 따라간다).
struct AppCommands: Commands {

    let model: AppModel

    /// 텍스트 편집 중에는 파일 조작 단축키를 비활성화한다.
    /// (Edit의 Cut/Copy/Paste/Select All은 **예외** — 위 주석 참조)
    private var isEditingText: Bool { model.isTextEditing }

    var body: some Commands {
        // MARK: File — Finder의 File 메뉴 구성
        //
        // 전부 `.newItem` 한 그룹에 넣는다. File 메뉴에 확실히 안착하는 placement이면서,
        // `.saveItem`을 교체하면 SwiftUI가 그 근처에 넣는 "Close"(⌘W)까지 함께 날아가기 때문이다.
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { model.createFolderInCurrentDirectory() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(isEditingText)

            Divider()

            Button("Open") { model.openSelection() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(isEditingText || model.directory.selection.isEmpty)

            // ⌘↓는 Finder와 같은 "선택 항목 열기". `Open`(⌘O)과 동작이 같지만 사용자가
            // 두 단축키를 모두 쓰므로 항목도 둘 다 남긴다.
            Button("Open Selection") { model.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(isEditingText || model.directory.selection.isEmpty)

            Divider()

            // architect B9 — Finder 정보창을 여는 공개 API가 없어 "Show in Finder"로 대체
            Button("Show in Finder") { model.revealInFinder() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(isEditingText || model.directory.selection.isEmpty)

            Button("Rename") { model.beginRenameSelection() }
                .keyboardShortcut(KeyEquivalent(Character(KeyScalar.f2)), modifiers: [])
                .disabled(isEditingText || !model.canRenameSelection)

            // 2026-08-18 — 즐겨찾기 등록/해제. 상태에 따라 **한 항목이 토글**된다(둘 다 띄우지 않는다).
            // 단축키는 Finder의 "Add to Sidebar"(⌃⌘T)를 따른다.
            Button(model.isFavoriteTargetRegistered ? "Remove from Favorites" : "Add to Favorites") {
                model.toggleFavoriteForCurrentTarget()
            }
            .keyboardShortcut("t", modifiers: [.control, .command])
            .disabled(isEditingText || model.favoriteTarget == nil)

            Divider()

            Button("Move to Trash") { model.trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(isEditingText || model.directory.selection.isEmpty)
        }

        // MARK: Edit — 표준 pasteboard 그룹을 **교체**해 한 벌만 남긴다
        //
        // 같은 ⌘C를 단 항목이 두 벌 있으면 어느 쪽이 먼저 잡히는지가 메뉴 순서에 좌우된다.
        // 하나로 합치고 동작을 분기하는 편이 라우팅을 예측 가능하게 만든다.
        // `Select All`은 이 그룹에 함께 들어 있어 교체와 함께 사라지므로 여기서 되살린다.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { model.editCut() }
                .keyboardShortcut("x", modifiers: .command)

            Button("Copy") { model.editCopy() }
                .keyboardShortcut("c", modifiers: .command)

            Button("Paste") { model.editPaste() }
                .keyboardShortcut("v", modifiers: .command)

            // Finder의 "Move Items Here" — ⌘C 후 ⌥⌘V로 이동한다. UniFinder는 ⌘X 잘라내기를
            // 유지한 채 이 항목만 얹는다(컨텍스트 메뉴에는 넣지 않는다 — Finder도 ⌥를 눌러야 나오는 숨은 항목).
            Button("Move Items Here") { model.editMoveItemsHere() }
                .keyboardShortcut("v", modifiers: [.option, .command])

            Divider()

            Button("Select All") { model.editSelectAll() }
                .keyboardShortcut("a", modifiers: .command)
        }

        // MARK: View
        CommandGroup(after: .toolbar) {
            Button(model.settings.showHidden ? "Hide Hidden Items" : "Show Hidden Items") {
                model.toggleHiddenItems()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Divider()

            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }

        // MARK: Go — 커스텀 메뉴라 View와 Window 사이에 놓인다(= Finder 순서)
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.navigation.canGoBack)

            Button("Forward") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.navigation.canGoForward)

            Button("Enclosing Folder") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.navigation.canGoUp)

            Divider()

            // Finder 표준에 맞춰 ⌘L → ⇧⌘G (2026-08-18 D단계).
            Button("Go to Folder…") { model.beginAddressEditing() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) { }
    }
}
