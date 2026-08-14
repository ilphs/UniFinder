import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// M3 리뷰 권장 1 회귀 — **판정 캐시(`DropDecision`)가 마스크를 이길 수 있는 범위**를 고정한다. ralph 작성.
///
/// `M3DropOperationMaskTests`는 캐시가 없거나 대상이 바뀐 경우를 덮고, 캐시가 살아 있는 경우는
/// "배지대로 실행된다"(방향 (a))만 확인했다. 그래서 반대 방향의 좁은 구멍이 남아 있었다:
///
/// > `recalled`가 있으면 **현재 마스크를 아예 보지 않는다**. 마지막 `validateDrop` 이후 Option이
/// > 눌린 채 드롭이 확정되고 AppKit이 재검증을 보내지 않으면, 캐시의 `.move`가 마스크의
/// > copy-only 제한을 덮어쓴다 — 캐시가 (a)를 닫는 대신 (b)의 축소판을 다시 연다.
///
/// 실현 확률은 낮지만 방향이 파괴적이다(원본 소실, 되돌림은 휴지통 복원뿐). 규칙은
/// **"현재 마스크가 그 판정을 여전히 허용할 때만 캐시를 쓴다"**이며, 여기서 (a)와 (b)를 함께 고정한다.
///
/// 캐시 수명(리뷰 선택 6 — 거부된 검증은 캐시를 남기지 않는다)도 같은 파일에서 확인한다:
/// 두 규칙이 한 자리(`acceptDrop`의 판정 입력)에서 만나기 때문이다.
@MainActor
final class M3DropDecisionRecallTests: TempDirectoryTestCase {

    /// `Coordinator.tableView`/`outlineView`는 weak라 테스트가 강한 참조를 들고 있어야 한다.
    private var retainedViews: [NSView] = []

    // MARK: - 정책 계층: settle(recalled:sourceMask:isSameVolume:)

    /// (a) 마스크가 둘 다 허용하면 배지로 보여준 판정을 그대로 유지한다.
    /// (수식키를 마우스 버튼보다 먼저 뗀 경우 — 마스크는 원래대로 돌아왔지만 사용자는 "복사"를 봤다)
    func testSettle_whenMaskStillAllowsRecalledKind_keepsRecalled() {
        XCTAssertEqual(
            DragDropPolicy.settle(recalled: .copy, sourceMask: [.copy, .move], isSameVolume: true),
            .copy,
            "마스크가 복사를 여전히 허용하는데 볼륨 기본값(이동)으로 뒤집으면 배지와 동작이 어긋난다"
        )
        XCTAssertEqual(
            DragDropPolicy.settle(recalled: .move, sourceMask: [.copy, .move], isSameVolume: false),
            .move,
            "볼륨 간 드롭이라도 마스크가 이동을 허용하면 배지로 보여준 이동이 유지된다"
        )
    }

    /// (b) 마스크가 한쪽으로 제한하면 **마스크가 이긴다** — 캐시가 소스의 제약을 덮어쓰면 안 된다.
    /// 이 케이스가 권장 1의 핵심이다: 캐시된 `.move`가 copy-only 마스크를 이기면 원본이 사라진다.
    func testSettle_whenMaskNarrowsToCopyOnly_overridesRecalledMove() {
        XCTAssertEqual(
            DragDropPolicy.settle(recalled: .move, sourceMask: .copy, isSameVolume: true),
            .copy,
            "소스가 복사만 허용한 순간에 캐시된 이동을 실행하면 원본이 사라진다(권장 1)"
        )
    }

    /// 반대 방향도 마스크가 이긴다 — 규칙이 "비파괴 쪽 편들기"가 아니라 "마스크 우선"임을 고정한다.
    func testSettle_whenMaskNarrowsToMoveOnly_overridesRecalledCopy() {
        XCTAssertEqual(
            DragDropPolicy.settle(recalled: .copy, sourceMask: .move, isSameVolume: false),
            .move
        )
    }

    func testSettle_withoutRecall_fallsBackToMaskJudgment() {
        XCTAssertEqual(DragDropPolicy.settle(recalled: nil, sourceMask: [.copy, .move], isSameVolume: true), .move)
        XCTAssertEqual(DragDropPolicy.settle(recalled: nil, sourceMask: [.copy, .move], isSameVolume: false), .copy)
        XCTAssertNil(DragDropPolicy.settle(recalled: nil, sourceMask: .link, isSameVolume: true))
    }

    /// 마스크가 이동·복사 어느 쪽도 허용하지 않으면 캐시가 있어도 받지 않는다 —
    /// `validateDrop`이 같은 입력에서 내리는 결론(거부)과 어긋나면 안 된다.
    func testSettle_whenMaskAllowsNeitherCopyNorMove_rejectsEvenWithRecall() {
        XCTAssertNil(DragDropPolicy.settle(recalled: .move, sourceMask: .link, isSameVolume: true))
        XCTAssertNil(DragDropPolicy.settle(recalled: .copy, sourceMask: [], isSameVolume: true))
    }

    /// `.generic` 단독 마스크는 복사만 근거가 된다(권장 2) — 캐시된 이동을 지탱하지 못한다.
    func testSettle_genericOnlyMask_doesNotSustainRecalledMove() {
        XCTAssertEqual(DragDropPolicy.settle(recalled: .move, sourceMask: .generic, isSameVolume: true), .copy)
        XCTAssertEqual(DragDropPolicy.settle(recalled: .copy, sourceMask: .generic, isSameVolume: true), .copy)
    }

    /// `permits`는 마스크를 **접기 전의 허용 집합**을 묻는다 — 결론끼리 비교하면
    /// `[.copy, .move]`가 "복사도 허용"이라는 사실을 잃는다(그 실수가 (a)를 깨뜨린다).
    func testPermits_readsTheAllowedSetNotTheCollapsedDecision() {
        XCTAssertTrue(DragDropPolicy.permits(.copy, sourceMask: [.copy, .move]))
        XCTAssertTrue(DragDropPolicy.permits(.move, sourceMask: [.copy, .move]))
        XCTAssertFalse(DragDropPolicy.permits(.move, sourceMask: .copy))
        XCTAssertFalse(DragDropPolicy.permits(.copy, sourceMask: .move))
        XCTAssertTrue(DragDropPolicy.permits(.copy, sourceMask: .generic))
        XCTAssertFalse(DragDropPolicy.permits(.move, sourceMask: .generic))
        XCTAssertFalse(DragDropPolicy.permits(.copy, sourceMask: .link))
        XCTAssertFalse(DragDropPolicy.permits(.move, sourceMask: []))
    }

    // MARK: - 목록 브릿지

    private func makeListCoordinator(
        currentDirectory: URL,
        items: [FileItem] = [],
        onDrop: @escaping ([URL], URL, FileOperationKind) -> Void
    ) -> FileListBridge.Coordinator {
        var selection = Set<URL>()
        let bridge = FileListBridge(
            items: items,
            revision: 1,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            currentDirectory: currentDirectory,
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "M3DropRecall-\(UUID().uuidString)")!),
            onOpen: { _ in },
            onNavigateUp: {},
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: { _ in },
            onDrop: onDrop
        )
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView()
        retainedViews.append(tableView)
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(SortKey.name.columnIdentifier)))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.items = items
        tableView.reloadData()
        return coordinator
    }

    /// **권장 1의 negative control**: 마지막 검증에서는 이동으로 판정됐는데, 드롭이 확정되는 순간의
    /// 마스크는 복사만 허용한다(Option이 마지막 `validateDrop` 이후에 눌린 채 놓인 경우 —
    /// AppKit이 재검증을 보내지 않으면 캐시만 남는다). 캐시가 무조건 이기면 여기서 원본이 사라진다.
    func testList_acceptDrop_whenMaskNarrowsToCopyAfterValidatedMove_executesCopy() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeListCoordinator(currentDirectory: destination) { _, _, kind in
            executed.append(kind)
        }

        // 1) 수식키 없이 같은 볼륨 — "이동" 배지로 판정되어 캐시에 남는다
        let info = MockDraggingInfo(urls: [source], sourceMask: [.copy, .move])
        let badge = coordinator.tableView(
            coordinator.tableView!, validateDrop: info, proposedRow: -1, proposedDropOperation: .above
        )
        XCTAssertEqual(badge, .move)

        // 2) 드롭이 확정되는 순간 마스크는 복사만 허용한다(재검증 없이 acceptDrop이 온 경우)
        info.draggingSourceOperationMask = .copy
        _ = coordinator.tableView(coordinator.tableView!, acceptDrop: info, row: -1, dropOperation: .above)

        XCTAssertEqual(
            executed, [.copy],
            "캐시된 이동이 copy-only 마스크를 덮어쓰면 소스가 허용하지 않은 삭제가 일어난다(권장 1)"
        )
    }

    /// 마스크가 이동·복사 어느 쪽도 허용하지 않는 상태로 확정되면, 캐시가 있어도 실행하지 않는다.
    func testList_acceptDrop_whenMaskLosesCopyAndMoveAfterValidate_isRejected() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeListCoordinator(currentDirectory: destination) { _, _, kind in
            executed.append(kind)
        }

        let info = MockDraggingInfo(urls: [source], sourceMask: [.copy, .move])
        _ = coordinator.tableView(
            coordinator.tableView!, validateDrop: info, proposedRow: -1, proposedDropOperation: .above
        )

        info.draggingSourceOperationMask = .link
        let accepted = coordinator.tableView(
            coordinator.tableView!, acceptDrop: info, row: -1, dropOperation: .above
        )

        XCTAssertFalse(accepted)
        XCTAssertTrue(executed.isEmpty, "판정 근거가 사라진 마스크 위에서 캐시를 실행하면 안 된다")
    }

    /// **선택 6의 negative control**: 판정을 내지 못한 검증은 이유를 가리지 않고 캐시를 남기지 않는다.
    /// (여기서는 파스트보드가 비어 거부되는 경로 — 예전 구현은 이 경로에서 `clear()`를 하지 않았다)
    func testList_validateRejection_discardsPreviousDecision() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeListCoordinator(currentDirectory: destination) { _, _, kind in
            executed.append(kind)
        }

        // 1) 복사로 판정되어 캐시에 남는다
        let copyOnly = MockDraggingInfo(urls: [source], sourceMask: .copy)
        XCTAssertEqual(
            coordinator.tableView(
                coordinator.tableView!, validateDrop: copyOnly, proposedRow: -1, proposedDropOperation: .above
            ),
            .copy
        )

        // 2) 파일이 아닌 드래그가 같은 대상 위를 지나가 거부된다 — 캐시는 여기서 사라져야 한다
        let empty = MockDraggingInfo(urls: [], sourceMask: .copy)
        XCTAssertEqual(
            coordinator.tableView(
                coordinator.tableView!, validateDrop: empty, proposedRow: -1, proposedDropOperation: .above
            ),
            []
        )

        // 3) 검증 없이 도착한 드롭(마스크는 둘 다 허용) — 낡은 캐시가 아니라 마스크로 판정해야 한다
        let both = MockDraggingInfo(urls: [source], sourceMask: [.copy, .move])
        _ = coordinator.tableView(coordinator.tableView!, acceptDrop: both, row: -1, dropOperation: .above)

        XCTAssertEqual(
            executed, [.move],
            "거부된 검증이 캐시를 남기면 사용자에게 보여준 적 없는 판정이 나중에 실행된다(선택 6)"
        )
    }

    /// 드롭 1건이 끝나면 캐시는 비워진다 — 다음 드롭이 이전 배지를 물려받지 않는다.
    func testList_acceptDrop_doesNotLeakDecisionToTheNextDrop() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeListCoordinator(currentDirectory: destination) { _, _, kind in
            executed.append(kind)
        }

        let copyOnly = MockDraggingInfo(urls: [source], sourceMask: .copy)
        _ = coordinator.tableView(
            coordinator.tableView!, validateDrop: copyOnly, proposedRow: -1, proposedDropOperation: .above
        )
        _ = coordinator.tableView(coordinator.tableView!, acceptDrop: copyOnly, row: -1, dropOperation: .above)

        // 두 번째 드롭은 검증 없이 도착했다 — 첫 드롭의 "복사"가 남아 있으면 안 된다
        let both = MockDraggingInfo(urls: [source], sourceMask: [.copy, .move])
        _ = coordinator.tableView(coordinator.tableView!, acceptDrop: both, row: -1, dropOperation: .above)

        XCTAssertEqual(executed, [.copy, .move])
    }

    // MARK: - 트리 브릿지 (목록과 같은 규칙이어야 한다)

    private func makeTreeCoordinator(
        onDrop: @escaping ([URL], URL, FileOperationKind) -> Void
    ) -> SidebarTreeBridge.Coordinator {
        let bridge = SidebarTreeBridge(
            model: TreeModel(loader: DirectoryLoader(), homeURL: testRoot),
            revision: 1,
            focusBroker: FocusBroker(),
            onDrop: onDrop,
            onSelect: { _ in },
            onRefresh: {}
        )
        let coordinator = bridge.makeCoordinator()
        let outlineView = KeyRoutingOutlineView()
        retainedViews.append(outlineView)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.outlineView = outlineView
        return coordinator
    }

    private func folderNode(_ url: URL) -> TreeNode {
        TreeNode(kind: .folder, url: url, name: url.lastPathComponent, isSymlink: false, parent: nil)
    }

    /// 권장 1의 트리 쪽 negative control — 두 브릿지가 **같은** 규칙을 써야 한다.
    func testTree_acceptDrop_whenMaskNarrowsToCopyAfterValidatedMove_executesCopy() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeTreeCoordinator { _, _, kind in executed.append(kind) }
        let node = folderNode(destination)

        let info = MockDraggingInfo(urls: [source], sourceMask: [.copy, .move])
        let badge = coordinator.outlineView(
            coordinator.outlineView!,
            validateDrop: info,
            proposedItem: node,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        )
        XCTAssertEqual(badge, .move)

        info.draggingSourceOperationMask = .copy
        _ = coordinator.outlineView(
            coordinator.outlineView!, acceptDrop: info, item: node, childIndex: NSOutlineViewDropOnItemIndex
        )

        XCTAssertEqual(
            executed, [.copy],
            "트리에서도 캐시가 copy-only 마스크를 덮어쓰면 안 된다(목록→트리 / 트리→트리 일관성)"
        )
    }

    func testTree_acceptDrop_whenMaskLosesCopyAndMoveAfterValidate_isRejected() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeTreeCoordinator { _, _, kind in executed.append(kind) }
        let node = folderNode(destination)

        let info = MockDraggingInfo(urls: [source], sourceMask: [.copy, .move])
        _ = coordinator.outlineView(
            coordinator.outlineView!,
            validateDrop: info,
            proposedItem: node,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        )

        info.draggingSourceOperationMask = .link
        let accepted = coordinator.outlineView(
            coordinator.outlineView!, acceptDrop: info, item: node, childIndex: NSOutlineViewDropOnItemIndex
        )

        XCTAssertFalse(accepted)
        XCTAssertTrue(executed.isEmpty)
    }

    /// 선택 6의 트리 쪽 — 거부된 검증(드래그 중인 노드 자신 위)이 캐시를 남기지 않는다.
    func testTree_validateRejection_discardsPreviousDecision() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeTreeCoordinator { _, _, kind in executed.append(kind) }
        let node = folderNode(destination)

        let copyOnly = MockDraggingInfo(urls: [source], sourceMask: .copy)
        XCTAssertEqual(
            coordinator.outlineView(
                coordinator.outlineView!,
                validateDrop: copyOnly,
                proposedItem: node,
                proposedChildIndex: NSOutlineViewDropOnItemIndex
            ),
            .copy
        )

        let empty = MockDraggingInfo(urls: [], sourceMask: .copy)
        XCTAssertEqual(
            coordinator.outlineView(
                coordinator.outlineView!,
                validateDrop: empty,
                proposedItem: node,
                proposedChildIndex: NSOutlineViewDropOnItemIndex
            ),
            []
        )

        let both = MockDraggingInfo(urls: [source], sourceMask: [.copy, .move])
        _ = coordinator.outlineView(
            coordinator.outlineView!, acceptDrop: both, item: node, childIndex: NSOutlineViewDropOnItemIndex
        )

        XCTAssertEqual(executed, [.move], "거부된 검증이 캐시를 남기면 안 된다(선택 6)")
    }
}
