import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// M3 T4 QuickLook — Space 키 분기 회귀 테스트 (m3-impl B14).
///
/// B14: "타입-어헤드 진행 중이면 Space는 검색 문자열에 포함, 아니면 QuickLook" 우선순위 규칙은
/// **M1/M2 코드가 이미 정확히 구현**하고 있고(주석: "M3 QuickLook 예약"), T4는 그 자리에
/// `onQuickLook` 콜백을 꽂는 작업이다(분기 구조 재작성 금지). 이 파일은 그 두 분기를 고정한다.
///
/// **가정하는 프로덕션 변경**: `FileListBridge`에 `onQuickLook: () -> Void = {}` 콜백이 추가되고,
/// `Coordinator.handleTypeAhead`의 "진행 중 아님" 분기(예전엔 `return true`로 무동작)가
/// `parent.onQuickLook()`을 호출한 뒤 `true`를 반환한다.
@MainActor
final class QuickLookSpaceKeyRegressionTests: XCTestCase {

    private var retainedTableViews: [KeyRoutingTableView] = []

    private func makeItem(name: String) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/ql-space-tests").appendingPathComponent(name),
            name: name,
            isDirectory: false,
            isHidden: false,
            isSymlink: false,
            size: 10,
            modifiedAt: Fixture.fixedDate(),
            typeDescription: "파일"
        )
    }

    private func makeCoordinator(
        items: [FileItem] = [],
        onTypeAhead: @escaping (String) -> Void = { _ in },
        onQuickLook: @escaping () -> Void = {}
    ) -> FileListBridge.Coordinator {
        var selection = Set<URL>()
        let bridge = FileListBridge(
            items: items,
            revision: 1,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "QuickLookSpaceKeyTests-\(UUID().uuidString)")!),
            onOpen: { _ in },
            onNavigateUp: {},
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: onTypeAhead,
            onQuickLook: onQuickLook
        )
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView()
        retainedTableViews.append(tableView)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(SortKey.name.columnIdentifier)))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.items = items
        tableView.reloadData()
        return coordinator
    }

    private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    private var spaceCharacter: String { String(KeyScalar.space) }

    // MARK: - 회귀: 타입-어헤드 진행 중 Space는 검색 문자열에 포함

    func testSpace_whileTypeAheadIsActive_isAppendedToSearchBuffer_andDoesNotOpenQuickLook() {
        var typeAheadCalls: [String] = []
        var quickLookCount = 0
        let items = [makeItem(name: "hello world.txt")]
        let coordinator = makeCoordinator(
            items: items,
            onTypeAhead: { typeAheadCalls.append($0) },
            onQuickLook: { quickLookCount += 1 }
        )

        // 1) 일반 문자로 타입-어헤드를 먼저 활성화한다.
        _ = coordinator.handleKeyDown(keyEvent("h"))
        // 2) 곧바로 Space — 1초 유예 안이라 "진행 중"이다.
        let handled = coordinator.handleKeyDown(keyEvent(spaceCharacter))

        XCTAssertTrue(handled, "Space는 타입-어헤드 진행 중에도 브릿지가 소비해야 함(비프음 방지)")
        XCTAssertEqual(typeAheadCalls.last, "h ", "진행 중 Space는 검색 버퍼에 포함되어야 함(B14 회귀)")
        XCTAssertEqual(quickLookCount, 0, "타입-어헤드 진행 중에는 QuickLook이 열리면 안 된다(우선순위 규칙)")
    }

    // MARK: - 신규: 타입-어헤드 비진행 중 Space는 QuickLook 토글

    func testSpace_whenTypeAheadIsNotActive_invokesOnQuickLook_andDoesNotTouchSearchBuffer() {
        var typeAheadCalls: [String] = []
        var quickLookCount = 0
        let items = [makeItem(name: "a.txt")]
        let coordinator = makeCoordinator(
            items: items,
            onTypeAhead: { typeAheadCalls.append($0) },
            onQuickLook: { quickLookCount += 1 }
        )

        let handled = coordinator.handleKeyDown(keyEvent(spaceCharacter))

        XCTAssertTrue(handled, "Space는 항상 브릿지가 소비해야 함")
        XCTAssertEqual(quickLookCount, 1, "타입-어헤드 비진행 중 Space는 QuickLook을 열어야 한다(T4)")
        XCTAssertTrue(typeAheadCalls.isEmpty, "QuickLook을 여는 Space가 검색 버퍼를 건드리면 안 된다")
    }

    /// 타입-어헤드 버퍼가 비어 있으면(직전 입력이 없거나 타임아웃) "진행 중"으로 치지 않는다 —
    /// 기존 규칙(`!typeAheadBuffer.isEmpty`)이 T4 이후에도 유지되는지.
    func testSpace_afterEscapeResetsTypeAhead_thenInvokesQuickLookInstead() {
        var quickLookCount = 0
        let items = [makeItem(name: "a.txt")]
        let coordinator = makeCoordinator(items: items, onQuickLook: { quickLookCount += 1 })

        _ = coordinator.handleKeyDown(keyEvent("a"))
        _ = coordinator.handleKeyDown(keyEvent(String(KeyScalar.escape)))
        let handled = coordinator.handleKeyDown(keyEvent(spaceCharacter))

        XCTAssertTrue(handled)
        XCTAssertEqual(quickLookCount, 1, "Escape로 타입-어헤드가 리셋된 뒤의 Space는 QuickLook을 열어야 한다")
    }
}
