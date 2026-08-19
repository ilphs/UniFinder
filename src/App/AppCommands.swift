import AppKit
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
///
/// **다중 창 라우팅 (T6a)**: 창이 여러 개가 되면서 "어느 창의 모델인가"를 앱이 정해줄 수 없게 됐다.
/// `@FocusedValue(AppModel.self)`로 **활성 창이 게시한 모델**을 집어간다.
///
/// 게시는 반드시 `focusedSceneValue`여야 한다(`focusedValue` 금지). 이 앱의 first responder는
/// `NSTableView`/`NSOutlineView`(AppKit 브릿지)라 **SwiftUI 포커스 체인에 뷰가 없다** —
/// `focusedValue`는 "포커스된 SwiftUI 뷰"가 있어야 값을 게시하므로 값이 영영 `nil`이 되고
/// File/View/Go 메뉴가 통째로 비활성 상태로 굳는다. `focusedSceneValue`는 **활성 씬** 기준이라
/// AppKit이 포커스를 쥐고 있어도 게시된다. 되돌리지 말 것.
struct AppCommands: Commands {

    /// macOS 14의 Observable 전용 오버로드 — 커스텀 `FocusedValueKey`도 `Equatable` 채택도 필요 없다.
    @FocusedValue(AppModel.self) private var model: AppModel?

    /// 활성 씬이 게시한 새로고침 동작 (reviewer minor #8) — Disk Usage 창처럼 `AppModel`이 없는
    /// 창도 ⌘R을 쓸 수 있어야 하므로 모델과 **별도 채널**로 받는다.
    @FocusedValue(\.sceneRefresh) private var sceneRefresh: SceneRefreshAction?

    /// 텍스트 편집 중에는 파일 조작 단축키를 비활성화한다.
    /// (Edit의 Cut/Copy/Paste/Select All은 **예외** — 위 주석 참조)
    ///
    /// 활성 창이 없으면(`model == nil`) 편집 중이 아닌 것으로 본다 — 그래야 아래 `disabled`
    /// 계산이 `nil` 판정 한 곳으로 모인다.
    private var isEditingText: Bool { model?.isTextEditing ?? false }

    /// 활성 창이 없으면 파일 액션은 대상이 없다. **`.pasteboard` 그룹에는 적용하지 않는다** —
    /// 이유는 타입 주석의 "텍스트 편집과의 공존" 참조.
    private var hasNoFocusedWindow: Bool { model == nil }

    var body: some Commands {
        // MARK: File — Finder의 File 메뉴 구성
        //
        // 전부 `.newItem` 한 그룹에 넣는다. File 메뉴에 확실히 안착하는 placement이면서,
        // `.saveItem`을 교체하면 SwiftUI가 그 근처에 넣는 "Close"(⌘W)까지 함께 날아가기 때문이다.
        CommandGroup(replacing: .newItem) {
            // **다중 창 T6b** — `WindowGroup`은 자동으로 "New Window"(⌘N)를 이 자리에 넣는데,
            // `replacing: .newItem`이 그것을 통째로 교체하므로 여기서 직접 되살린다.
            // `after:`로 바꾸면 자동 항목이 살아남아 **⌘N이 두 개**가 되니 `replacing:`을 유지할 것.
            //
            // 시작 폴더는 **현재 창의 폴더**다(Win10 탐색기 방식 — 사용자 결정).
            // 활성 창이 없으면(`model == nil`) 홈으로 연다 — 시드의 `folderPath`가 `nil`이면
            // `AppModel`이 홈으로 폴백하므로 별도 분기가 필요 없다.
            //
            // `@Environment(\.openWindow)`는 **`Commands`가 아니라 `View`에** 둔다(Apple 문서 패턴).
            // 그래서 항목 하나를 전용 뷰로 뽑았다.
            NewWindowButton(folderURL: model?.navigation.currentURL)

            Divider()

            Button("New Folder") { model?.createFolderInCurrentDirectory() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(hasNoFocusedWindow || isEditingText)

            Divider()

            Button("Open") { model?.openSelection() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(hasNoFocusedWindow || isEditingText || model?.directory.selection.isEmpty != false)

            // ⌘↓는 Finder와 같은 "선택 항목 열기". `Open`(⌘O)과 동작이 같지만 사용자가
            // 두 단축키를 모두 쓰므로 항목도 둘 다 남긴다.
            Button("Open Selection") { model?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(hasNoFocusedWindow || isEditingText || model?.directory.selection.isEmpty != false)

            Divider()

            // 후속 T5 — 자체 Get Info 창. **`Cmd+I`의 유일한 소유자**다(UI설계 §10 불변식).
            // 다중 선택에서는 비활성 — `Rename`과 같은 규칙이다(D2).
            GetInfoButton(target: model?.infoTarget)
                .disabled(hasNoFocusedWindow || isEditingText || model?.infoTarget == nil)

            // architect B9의 승계 — followup-impl §1.2.
            // "Finder 정보창을 여는 공개 API가 없다"는 전제는 **지금도 참**이고, 우리가 여는 것은
            // Finder의 창이 아니라 우리 자신의 Get Info 창이다. 그래서 결론만 확장됐다:
            // 이 항목은 유지하되 **단축키를 잃는다**(⌘I는 위 Get Info 하나만 갖는다).
            // 단축키 하나에 항목이 둘이면 어느 쪽이 잡히는지가 메뉴 순서라는 우연에 좌우된다.
            Button("Show in Finder") { model?.revealInFinder() }
                .disabled(hasNoFocusedWindow || isEditingText || model?.directory.selection.isEmpty != false)

            Button("Rename") { model?.beginRenameSelection() }
                .keyboardShortcut(KeyEquivalent(Character(KeyScalar.f2)), modifiers: [])
                .disabled(hasNoFocusedWindow || isEditingText || model?.canRenameSelection != true)

            // 2026-08-18 — 즐겨찾기 등록/해제. 상태에 따라 **한 항목이 토글**된다(둘 다 띄우지 않는다).
            // 단축키는 Finder의 "Add to Sidebar"(⌃⌘T)를 따른다.
            Button(model?.isFavoriteTargetRegistered == true ? "Remove from Favorites" : "Add to Favorites") {
                model?.toggleFavoriteForCurrentTarget()
            }
            .keyboardShortcut("t", modifiers: [.control, .command])
            .disabled(hasNoFocusedWindow || isEditingText || model?.favoriteTarget == nil)

            Divider()

            Button("Move to Trash") { model?.trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(hasNoFocusedWindow || isEditingText || model?.directory.selection.isEmpty != false)
        }

        // MARK: Edit — 표준 pasteboard 그룹을 **교체**해 한 벌만 남긴다
        //
        // 같은 ⌘C를 단 항목이 두 벌 있으면 어느 쪽이 먼저 잡히는지가 메뉴 순서에 좌우된다.
        // 하나로 합치고 동작을 분기하는 편이 라우팅을 예측 가능하게 만든다.
        // `Select All`은 이 그룹에 함께 들어 있어 교체와 함께 사라지므로 여기서 되살린다.
        //
        // **다중 창 T6a — 이 4개 항목만은 `model == nil`이어도 절대 `.disabled`로 내리지 않는다.**
        // 활성 창이 없다고 비활성화하면 ⌘X/⌘C/⌘V/⌘A를 달고 있는 메뉴 항목이 하나도 없게 되어
        // 주소창·인라인 rename·시트의 텍스트 편집 복사/붙여넣기가 통째로 죽는다(위 주석과 같은 이유).
        // `model?`의 옵셔널 체이닝은 "대상이 없으면 아무 일도 안 한다"로 끝나므로 안전하고,
        // 텍스트 편집은 `AppModel` 없이도 아래 `NSApp.sendAction` 폴백이 처리한다.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { editAction(#selector(NSText.cut(_:))) { $0.editCut() } }
                .keyboardShortcut("x", modifiers: .command)

            Button("Copy") { editAction(#selector(NSText.copy(_:))) { $0.editCopy() } }
                .keyboardShortcut("c", modifiers: .command)

            Button("Paste") { editAction(#selector(NSText.paste(_:))) { $0.editPaste() } }
                .keyboardShortcut("v", modifiers: .command)

            // Finder의 "Move Items Here" — ⌘C 후 ⌥⌘V로 이동한다. UniFinder는 ⌘X 잘라내기를
            // 유지한 채 이 항목만 얹는다(컨텍스트 메뉴에는 넣지 않는다 — Finder도 ⌥를 눌러야 나오는 숨은 항목).
            // 이것만은 텍스트 단축키가 아니라 활성 창이 없으면 할 일이 없다.
            Button("Move Items Here") { model?.editMoveItemsHere() }
                .keyboardShortcut("v", modifiers: [.option, .command])

            Divider()

            Button("Select All") { editAction(#selector(NSText.selectAll(_:))) { $0.editSelectAll() } }
                .keyboardShortcut("a", modifiers: .command)
        }

        // MARK: View
        CommandGroup(after: .toolbar) {
            Button(model?.settings.showHidden == true ? "Hide Hidden Items" : "Show Hidden Items") {
                model?.toggleHiddenItems()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(hasNoFocusedWindow)

            Divider()

            // **⌘R의 유일한 소유자**(reviewer minor #8 / ⌘I와 같은 원칙). 무엇을 새로고침할지는
            // 활성 씬이 `sceneRefresh`로 게시한다 — 메인 창은 폴더 목록, Disk Usage 창은 볼륨 용량.
            // 게시가 없을 때는 예전 경로(`model?.refresh()`)로 떨어진다: 이 폴백이 있어야
            // 씬 값이 어떤 이유로든 비어도 메인 창의 ⌘R이 죽지 않는다.
            Button("Refresh") {
                // 활성 씬의 게시값이 우선, 없으면 활성 창의 모델로 떨어진다.
                if let sceneRefresh {
                    sceneRefresh()
                } else {
                    model?.refresh()
                }
            }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(sceneRefresh == nil && hasNoFocusedWindow)

            Divider()

            // 후속 T8 — 디스크 용량 창. 활성 창과 무관한 앱 전역 정보라 `model`에 기대지 않는다
            // (창이 하나도 없어도 열 수 있어야 한다).
            DiskCapacityButton()
        }

        // MARK: Go — 커스텀 메뉴라 View와 Window 사이에 놓인다(= Finder 순서)
        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model?.navigation.canGoBack != true)

            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model?.navigation.canGoForward != true)

            Button("Enclosing Folder") { model?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model?.navigation.canGoUp != true)

            Divider()

            // Finder 표준에 맞춰 ⌘L → ⇧⌘G (2026-08-18 D단계).
            Button("Go to Folder…") { model?.beginAddressEditing() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(hasNoFocusedWindow)
        }

        // MARK: Help — 업데이트 확인 (후속 T3 / D8)
        //
        // 이 그룹은 예전부터 **비어 있었다**(SwiftUI 기본 "UniFinder Help"를 없애려고 교체만 해 둔 상태).
        // 그래서 여기에 항목을 넣는 것은 잃을 것이 없다. macOS 관례상 `Check for Updates…`는
        // 앱 메뉴(`.appInfo` 근처)에 두는 경우가 많지만, 그 영역은 About/Settings/Services/Quit이
        // 밀집해 있어 교체 한 번에 `Quit`(⌘Q)까지 사라지는 사고가 나기 쉽다 —
        // `.saveItem` 교체로 `Close`를 잃은 전례가 이미 있다(위 File 메뉴 주석). 리스크가 0인 자리를 택했다.
        CommandGroup(replacing: .help) {
            CheckForUpdatesButton()
            AutomaticUpdateCheckToggle()
        }
    }

    /// Edit의 pasteboard 액션 실행부 (다중 창 T6a).
    ///
    /// 활성 창이 있으면 `AppModel`이 `editActionTarget`으로 텍스트/파일을 분기한다.
    /// 활성 창이 **없을 때도** 동작해야 한다 — 시트만 떠 있거나 창이 하나도 없는 상태에서도
    /// 텍스트 필드의 복사/붙여넣기는 살아 있어야 하므로 responder chain으로 그대로 넘긴다
    /// (`AppModel.forwardToTextResponder`의 기본 구현과 같은 경로).
    private func editAction(_ selector: Selector, _ action: (AppModel) -> Void) {
        guard let model else {
            NSApp?.sendAction(selector, to: nil, from: nil)
            return
        }
        action(model)
    }
}

/// File > New Window (⌘N) — 다중 창 T6b.
///
/// 메뉴 항목이면서도 별도 `View`인 이유: `openWindow` 환경 값은 `Commands` 타입이 아니라
/// **뷰 계층**에서 읽는 것이 Apple이 문서화한 사용법이다.
///
/// 시작 폴더는 **현재 창의 폴더**(Win10 탐색기 방식). `nil`이면 홈으로 연다 —
/// `WindowSeed.folderPath`가 `nil`이면 `AppModel`이 홈으로 폴백하므로 분기가 필요 없다.
struct NewWindowButton: View {

    let folderURL: URL?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: UniFinderApp.mainWindowID, value: WindowSeed(folderURL: folderURL))
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

/// File > Get Info (⌘I) — 후속 T5.
///
/// `NewWindowButton`과 같은 이유로 별도 `View`다: `openWindow` 환경 값은 `Commands` 타입이 아니라
/// **뷰 계층**에서 읽는 것이 Apple이 문서화한 사용법이다.
///
/// **`Cmd+I`는 앱 전체에서 이 항목 하나만 갖는다**(UI설계 §10 불변식). `Show in Finder`에서
/// 이 단축키를 되살리면 AppKit이 메뉴 순서에 따라 아무 쪽이나 잡게 되어 동작이 예측 불가가 된다.
struct GetInfoButton: View {

    /// 정보를 볼 대상. `nil`이면(선택 없음·다중 선택) 항목이 비활성이다 — D2.
    let target: URL?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Get Info") {
            guard let target else { return }
            openWindow(id: UniFinderApp.infoWindowID, value: InfoTarget(url: target))
        }
        .keyboardShortcut("i", modifiers: .command)
    }
}

/// View > Disk Capacity… — 후속 T8.
struct DiskCapacityButton: View {

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Disk Capacity…") {
            openWindow(id: UniFinderApp.diskCapacityWindowID)
        }
    }
}

/// Help > Check for Updates… (후속 T3).
///
/// **활성 창(`@FocusedValue`)에 기대지 않는다**: 업데이트 확인은 창의 상태가 아니라 앱의 상태다.
/// 창이 하나도 없어도(Dock에서 앱만 살아 있는 상태) 눌릴 수 있어야 하므로 앱 전역 인스턴스를
/// 직접 집는다. **참조는 `body` 안에서만** 한다 — 저장 프로퍼티로 두면 `AppCommands`가 만들어지는
/// 순간(테스트가 씬 타입만 확인하는 경로 포함) `AppEnvironment.shared`가 깨어난다.
///
/// 단축키는 주지 않는다. Finder를 비롯한 macOS 앱들이 이 항목에 단축키를 두지 않고,
/// 남는 조합을 억지로 잡으면 다른 앱과 근육기억이 어긋난다.
/// **진행 중에는 제목이 바뀌고 비활성이 된다**(reviewer minor #10): 확인은 timeout까지
/// 최대 10초가 걸리는데, 그동안 항목이 평소와 똑같아 보이면 사용자는 눌리지 않은 줄 알고
/// 다시 누른다(그때마다 이전 확인이 취소되고 새 요청이 나간다). `UpdateCheckModel.isChecking`이
/// 이 표시의 유일한 근거다.
struct CheckForUpdatesButton: View {

    var body: some View {
        // 지역 상수로 한 번만 집는다 — `body` 밖(저장 프로퍼티)으로 나가면 안 되는 참조다.
        let environment = AppEnvironment.shared
        let isChecking = environment.update.isChecking
        Button(Self.title(isChecking: isChecking)) {
            environment.update.checkManually()
        }
        // **창이 0개면 결과를 표시할 곳이 없다**(reviewer major #2).
        // 결과 알림은 소유 창의 `.alert`가 그리므로, 창이 없으면 성공/최신/실패 어느 쪽도
        // 화면에 뜨지 않고 조용히 사라진다. 물어봐야 답할 수 없으니 항목 자체를 내린다
        // (File/View/Go의 `hasNoFocusedWindow` 가드와 같은 패턴).
        .disabled(Self.isDisabled(isChecking: isChecking, canPresentGlobalAlert: environment.canPresentGlobalAlert))
    }

    /// 문구·활성 판정은 **뷰를 띄우지 않고 단언할 수 있도록** 정적 함수로 뺀다
    /// (SwiftUI `Commands`는 단위 테스트에서 렌더링할 수 없다 — `AutomaticUpdateCheckToggle.binding` 선례).
    static func title(isChecking: Bool) -> String {
        isChecking ? "Checking for Updates…" : "Check for Updates…"
    }

    static func isDisabled(isChecking: Bool, canPresentGlobalAlert: Bool) -> Bool {
        isChecking || !canPresentGlobalAlert
    }
}

/// Help > Automatically Check for Updates — 자동 확인 on/off (설계서 §1.2 경계 (d)).
///
/// **이 토글이 없으면 설계서가 승인한 네트워크 예외의 전제가 무너진다**: §1.2는 업데이트 확인을
/// 예외로 허용하면서 조건 (d)로 "사용자가 끌 수 있다"를 달았다. `UpdatePreferences.autoCheckEnabled`가
/// 값을 이미 저장하고 있었지만 그 값을 바꿀 UI가 어디에도 없어, 실질적으로는 끌 수 없는 기능이었다.
///
/// 자리는 `Check for Updates…` 바로 아래다 — 같은 기능의 "지금 확인"과 "앞으로도 확인"을
/// 붙여 두는 것이 macOS 앱들의 관례이고, 설정 창이 없는 이 앱에서 유일하게 자연스러운 위치다.
///
/// `Toggle`은 메뉴 안에서 체크마크 항목으로 그려지므로 현재 상태(Bool)가 그대로 보인다.
/// `Button`으로 문구를 뒤집는 방식(`Enable`/`Disable`)은 지금 상태가 켬인지 끔인지를
/// 사용자가 문구에서 역산해야 해서 쓰지 않는다.
struct AutomaticUpdateCheckToggle: View {

    var body: some View {
        // `CheckForUpdatesButton`과 같은 이유로 **`body` 안에서만** 공유 인스턴스를 집는다.
        Toggle("Automatically Check for Updates", isOn: Self.binding(for: AppEnvironment.shared.update.preferences))
    }

    /// 토글 ↔ `UpdatePreferences` 연결부. **뷰를 띄우지 않고 단언할 수 있도록** 따로 뺐다
    /// (SwiftUI `Commands`는 단위 테스트에서 렌더링할 수 없다).
    ///
    /// 읽기·쓰기 모두 `UpdatePreferences`를 직접 거친다 — 중간에 로컬 상태를 두면 `didSet`의
    /// `UserDefaults` 기록이 늦어져 "껐는데 다음 실행에서 다시 켜져 있다"가 된다.
    @MainActor
    static func binding(for preferences: UpdatePreferences) -> Binding<Bool> {
        Binding(
            get: { preferences.autoCheckEnabled },
            set: { preferences.autoCheckEnabled = $0 }
        )
    }
}
