import AppKit
import XCTest
@testable import UniFinder

/// first responder를 실제로 획득할 수 있는 최소 테스트 뷰.
/// (`NSOutlineView`/`NSTableView`처럼 자기 자신이 first responder가 되는 pane을 대역한다)
private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// 이동 후 포커스 정책 회귀 테스트 (code review 필수 수정 #1).
///
/// **재현 시나리오**: 트리에 포커스를 둔 채 방향키로 이동하면
/// `NSOutlineView` 선택 변경 → `AppModel.navigate(source: .tree)` → `loadCurrent()`가
/// 무조건 `focusBroker.focusListSoon()`을 호출해 first responder가 목록으로 끌려갔다.
/// 그 결과 다음 방향키를 트리가 받지 못해 트리 키보드 탐색이 아예 불가능했다.
@MainActor
final class NavigationFocusPolicyTests: TempDirectoryTestCase {

    private struct Stack {
        let model: AppModel
        let window: NSWindow
        let listView: NSView
        let treeView: NSView
        let child: URL
    }

    private func makeStack() throws -> Stack {
        let child = try Fixture.makeDirectory(in: testRoot, name: "child")

        // 디스크 열거를 배제하기 위해 로더는 mock(빈 결과)을 주입한다.
        // 경로 존재 여부만 실제 파일시스템(testRoot 하위)에 의존한다.
        let model = AppModel(loader: MockDirectoryListing(), startURL: testRoot)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let listView = FocusableTestView()
        let treeView = FocusableTestView()
        window.contentView?.addSubview(listView)
        window.contentView?.addSubview(treeView)

        model.focusBroker.register(listView: listView)
        model.focusBroker.register(treeView: treeView)

        return Stack(model: model, window: window, listView: listView, treeView: treeView, child: child)
    }

    /// `focusListSoon()`은 Task로 지연 실행되므로 결과를 관찰하려면 한 턴 이상 양보해야 한다.
    private func settleFocus() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func testNavigateFromTree_whileTreeIsFirstResponder_keepsFocusOnTree() async throws {
        let stack = try makeStack()
        XCTAssertTrue(stack.window.makeFirstResponder(stack.treeView))

        stack.model.navigate(to: stack.child, source: .tree)
        await settleFocus()

        XCTAssertTrue(
            stack.window.firstResponder === stack.treeView,
            "트리에서 시작된 이동은 first responder를 목록으로 끌어가면 안 됨(트리 방향키 탐색 불가 회귀)"
        )
        XCTAssertEqual(stack.model.navigation.currentURL.path, stack.child.path)
    }

    func testNavigateFromBreadcrumb_whileTreeIsFirstResponder_movesFocusToList() async throws {
        let stack = try makeStack()
        XCTAssertTrue(stack.window.makeFirstResponder(stack.treeView))

        stack.model.navigate(to: stack.child, source: .breadcrumb)
        await settleFocus()

        XCTAssertTrue(
            stack.window.firstResponder === stack.listView,
            "트리 외부(주소창/툴바/목록)에서 시작된 이동 후에는 포커스가 목록으로 가야 함(UI설계 §9)"
        )
    }

    func testNavigateFromTree_whileListIsFirstResponder_movesFocusToList() async throws {
        // 마우스로 트리 노드를 눌러 트리가 first responder가 되기 "전" 상태를 가정한 경계 케이스.
        let stack = try makeStack()
        XCTAssertTrue(stack.window.makeFirstResponder(stack.listView))

        stack.model.navigate(to: stack.child, source: .tree)
        await settleFocus()

        XCTAssertTrue(stack.window.firstResponder === stack.listView)
    }

    func testFocusBroker_reportsCurrentFocusTarget() throws {
        let stack = try makeStack()

        XCTAssertTrue(stack.window.makeFirstResponder(stack.treeView))
        XCTAssertEqual(stack.model.focusBroker.currentFocus, .tree)
        XCTAssertTrue(stack.model.focusBroker.isTreeFocused)

        XCTAssertTrue(stack.window.makeFirstResponder(stack.listView))
        XCTAssertEqual(stack.model.focusBroker.currentFocus, .list)
        XCTAssertFalse(stack.model.focusBroker.isTreeFocused)
    }
}
