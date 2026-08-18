import AppKit
import XCTest
@testable import UniFinder

/// Edit 메뉴 Cut/Copy/Paste/Select All의 **컨텍스트 인식 라우팅** — 2026-08-18 D단계.
///
/// 배경: Finder 구조에 맞추느라 파일 조작을 Edit 메뉴로 합치면서 `CommandGroup(replacing: .pasteboard)`
/// 로 표준 항목을 교체했다. 예전 회피책("편집 중에는 `.disabled`로 내려 텍스트 필드로 흘려보낸다")은
/// 더 쓸 수 없다 — ⌘C를 단 메뉴 항목이 **하나도 없게 되면** AppKit이 ⌘ 단축키를 메인 메뉴에서
/// 먼저 찾으므로 주소창·인라인 rename의 복사/붙여넣기가 통째로 죽는다.
/// 그래서 항목은 항상 활성으로 두고 **동작만** 분기한다. 여기서 그 분기를 고정한다.
///
/// **자동화 범위**: 분기 판정과 위임 셀렉터까지가 단위 테스트의 몫이다. field editor가 실제로
/// 텍스트를 자르고 붙이는지는 AppKit 기본 동작이라 여기서 검증하지 않는다(수동 게이트 소관).
@MainActor
final class AppModelEditMenuRoutingTests: TempDirectoryTestCase {

    /// 위임된 셀렉터를 기록하는 모델. responder chain 없이 분기만 관찰한다.
    private final class Recorder {
        var selectors: [Selector] = []
    }

    private func makeModel() -> (AppModel, Recorder) {
        let model = AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelEditRouting-\(UUID().uuidString)")!),
            operations: GatedFileOperating(),
            clipboard: ClipboardModel(
                pasteboard: NSPasteboard(name: NSPasteboard.Name("UniFinderEditRouting-\(UUID().uuidString)"))
            ),
            startURL: testRoot
        )
        let recorder = Recorder()
        model.forwardToTextResponder = { recorder.selectors.append($0) }
        // 테스트 프로세스에는 key window가 없다. 판정을 명시적으로 고정해 환경에 흔들리지 않게 한다.
        model.isTextResponderActive = { false }
        return (model, recorder)
    }

    /// `copy()`/`cut()`은 `directory.selectedItems`(= 로드된 목록 ∩ 선택)를 쓴다.
    /// 목록을 로드하지 않으면 선택을 세워도 조작 대상이 비어 라우팅 검증이 헛돈다.
    private func loadDirectoryAndSelect(_ url: URL, in model: AppModel) async {
        model.directory.load(url: testRoot)
        let deadline = Date().addingTimeInterval(3.0)
        while model.directory.items.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        model.directory.selection = [url]
    }

    // MARK: - 분기 판정

    func testEditActionTarget_defaultsToFiles() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.editActionTarget, .files)
    }

    func testEditActionTarget_isTextFieldWhileAddressEditing() {
        let (model, _) = makeModel()
        model.isAddressEditing = true
        XCTAssertEqual(model.editActionTarget, .textField)
    }

    func testEditActionTarget_isTextFieldWhileInlineRenaming() {
        let (model, _) = makeModel()
        model.isRenaming = true
        XCTAssertEqual(model.editActionTarget, .textField)
    }

    /// 모델이 모르는 편집기(충돌/온보딩 시트의 텍스트 필드)도 텍스트로 본다.
    /// 예전에는 표준 Edit 메뉴가 받아줬지만, 교체 후에는 이 판정이 유일한 안전망이다.
    func testEditActionTarget_isTextFieldWhenResponderChainHasTextEditor() {
        let (model, _) = makeModel()
        model.isTextResponderActive = { true }
        XCTAssertFalse(model.isTextEditing, "전제 확인 — 모델은 편집 중인 줄 모른다")
        XCTAssertEqual(model.editActionTarget, .textField)
    }

    // MARK: - 텍스트 편집 중: field editor로 위임하고 파일은 건드리지 않는다

    func testEditCutCopyPaste_whileTextEditing_forwardStandardSelectorsAndLeaveFilesAlone() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let (model, recorder) = makeModel()
        await loadDirectoryAndSelect(source, in: model)
        model.isAddressEditing = true

        model.editCut()
        model.editCopy()
        model.editPaste()

        XCTAssertEqual(
            recorder.selectors,
            [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:))],
            "텍스트 편집 중인데 표준 편집 셀렉터가 responder chain으로 위임되지 않았다"
        )
        XCTAssertTrue(model.clipboard.items.isEmpty, "텍스트 편집 중 ⌘C/⌘X가 파일을 클립보드에 올렸다")
        XCTAssertNil(model.clipboard.operation)
    }

    /// ⌥⌘V는 텍스트 단축키가 아니다 — 편집 중에는 아무 것도 하지 않는다.
    func testEditMoveItemsHere_whileTextEditing_isIgnored() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let (model, recorder) = makeModel()
        model.copy([source])
        model.isRenaming = true

        model.editMoveItemsHere()

        XCTAssertTrue(recorder.selectors.isEmpty, "⌥⌘V가 텍스트 편집기로 위임됐다")
        XCTAssertFalse(model.isOperationInProgress, "텍스트 편집 중에 파일 이동이 시작됐다")
    }

    // MARK: - 목록/트리 포커스: 파일 조작을 수행하고 위임하지 않는다

    func testEditCopy_withFileFocus_copiesSelectionAndDoesNotForward() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let (model, recorder) = makeModel()
        await loadDirectoryAndSelect(source, in: model)

        model.editCopy()

        XCTAssertTrue(recorder.selectors.isEmpty, "파일 포커스인데 텍스트로 위임했다")
        XCTAssertEqual(PathKey.key(model.clipboard.items), PathKey.key([source]))
        XCTAssertEqual(model.clipboard.operation, .copy)
    }

    func testEditCut_withFileFocus_cutsSelectionAndDoesNotForward() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let (model, recorder) = makeModel()
        await loadDirectoryAndSelect(source, in: model)

        model.editCut()

        XCTAssertTrue(recorder.selectors.isEmpty)
        XCTAssertEqual(PathKey.key(model.clipboard.items), PathKey.key([source]))
        XCTAssertEqual(model.clipboard.operation, .cut)
    }

    // MARK: - Select All (⌘A 생존)

    /// `.pasteboard` 그룹을 교체하면 표준 "Select All"이 **함께 사라진다**(실측 확인).
    /// 목록/트리에는 `selectAll` 핸들러가 없고 `NSTableView`/`NSOutlineView` 기본 구현에 기대므로,
    /// 되살린 항목은 어느 컨텍스트에서든 `selectAll:`을 responder chain으로 흘려보내야 한다.
    func testEditSelectAll_alwaysForwardsSelectAllSelector() {
        let (model, recorder) = makeModel()

        model.editSelectAll()
        model.isAddressEditing = true
        model.editSelectAll()

        XCTAssertEqual(
            recorder.selectors,
            [#selector(NSText.selectAll(_:)), #selector(NSText.selectAll(_:))],
            "⌘A가 responder chain으로 전달되지 않으면 목록 전체 선택과 텍스트 전체 선택이 함께 죽는다"
        )
    }

    /// 위임 셀렉터의 이름이 AppKit 표준과 어긋나면 responder chain이 조용히 아무 것도 하지 않는다.
    func testForwardedSelectors_matchAppKitStandardNames() {
        XCTAssertEqual(NSStringFromSelector(#selector(NSText.cut(_:))), "cut:")
        XCTAssertEqual(NSStringFromSelector(#selector(NSText.copy(_:))), "copy:")
        XCTAssertEqual(NSStringFromSelector(#selector(NSText.paste(_:))), "paste:")
        // 목록(`NSTableView`)·트리(`NSOutlineView`)·텍스트가 모두 같은 셀렉터를 구현한다.
        XCTAssertEqual(NSStringFromSelector(#selector(NSText.selectAll(_:))), "selectAll:")
        XCTAssertTrue(NSTableView.instancesRespond(to: #selector(NSText.selectAll(_:))))
        XCTAssertTrue(NSOutlineView.instancesRespond(to: #selector(NSText.selectAll(_:))))
    }
}
