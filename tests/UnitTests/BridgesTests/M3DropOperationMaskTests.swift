import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// M3 리뷰 blocker 1 회귀 — **드롭 판정의 입력이 무엇인가**를 고정한다. ralph 작성.
///
/// `DragDropPolicyTests`는 판정 함수의 순수 규칙만 본다. 그래서 브릿지가 `acceptDrop` 시점에
/// `NSEvent.modifierFlags`(전역 *현재* 상태)를 다시 읽는 결함이 그대로 통과했다:
/// - (a) `validateDrop`에서 "복사" 배지를 본 사용자가 마우스 버튼보다 Option을 먼저 떼면
///   `acceptDrop`이 이동을 실행한다 — 본 것과 다른, 그것도 **파괴적인** 방향의 동작
/// - (b) 소스가 `.copy`만 허용한 드래그도 같은 볼륨이면 이동으로 처리한다 — 파일을 소유한 앱
///   아래에서 원본이 사라진다
///
/// 그래서 이 파일은 **브릿지의 실제 콜백**(`validateDrop`/`acceptDrop`)을 `NSDraggingInfo` 대역으로
/// 직접 호출하고, 목록·트리 두 브릿지가 같은 규칙을 쓰는지까지 확인한다.
@MainActor
final class M3DropOperationMaskTests: TempDirectoryTestCase {

    /// `Coordinator.tableView`/`outlineView`는 weak라 테스트가 강한 참조를 들고 있어야 한다
    /// (지역 변수만 두면 헬퍼 반환과 함께 해제될 수 있다).
    private var retainedViews: [NSView] = []

    // MARK: - 판정 규칙 (마스크 교집합)

    func testOperation_sourceAllowsCopyOnly_neverYieldsMove_evenOnSameVolume() {
        XCTAssertEqual(
            DragDropPolicy.operation(sourceMask: .copy, isSameVolume: true),
            .copy,
            "소스가 복사만 허용했는데 이동으로 판정하면 원본이 사라진다(blocker 1-(b))"
        )
    }

    func testOperation_sourceAllowsMoveOnly_yieldsMove() {
        XCTAssertEqual(DragDropPolicy.operation(sourceMask: .move, isSameVolume: false), .move)
    }

    func testOperation_sourceAllowsBoth_fallsBackToVolumeDefault() {
        XCTAssertEqual(DragDropPolicy.operation(sourceMask: [.copy, .move], isSameVolume: true), .move)
        XCTAssertEqual(DragDropPolicy.operation(sourceMask: [.copy, .move], isSameVolume: false), .copy)
        XCTAssertEqual(DragDropPolicy.operation(sourceMask: .every, isSameVolume: true), .move)
    }

    /// Finder처럼 `.generic`을 함께 올리는 소스에서도 **명시 비트가 있으면 그쪽이 이긴다**.
    /// (Option이 눌려 `.copy`로 걸러진 마스크에 `.generic`이 남아 있어도 복사여야 한다)
    func testOperation_genericAlongsideCopy_stillYieldsCopy() {
        XCTAssertEqual(DragDropPolicy.operation(sourceMask: [.copy, .generic], isSameVolume: true), .copy)
    }

    /// **`.generic` 단독은 볼륨과 무관하게 복사다** (M3 리뷰 권장 2 — 기존 기대값을 뒤집었다).
    ///
    /// Cocoa 의미론상 `.generic`은 "동작은 대상이 정한다"라서 같은 볼륨 기본값(이동)을 골라도
    /// 틀린 해석은 아니었다. 하지만 그러면 **소스가 이동을 한 번도 명시하지 않았는데 원본을 지운다** —
    /// `DragDropPolicy`가 세운 원칙("모호한 입력에서는 비파괴 쪽")과 정면으로 어긋난다.
    func testOperation_genericOnly_prefersCopyOverVolumeDefault() {
        XCTAssertEqual(
            DragDropPolicy.operation(sourceMask: .generic, isSameVolume: true),
            .copy,
            "소스가 move를 명시하지 않은 모호한 마스크에서 원본을 지우면 안 된다(권장 2)"
        )
        XCTAssertEqual(DragDropPolicy.operation(sourceMask: .generic, isSameVolume: false), .copy)
    }

    func testOperation_noCopyOrMoveAllowed_isRejected() {
        XCTAssertNil(DragDropPolicy.operation(sourceMask: .link, isSameVolume: true))
        XCTAssertNil(DragDropPolicy.operation(sourceMask: [], isSameVolume: true))
    }

    // MARK: - 목록 브릿지 (FileListBridge)

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
            settings: AppSettings(defaults: UserDefaults(suiteName: "M3DropMask-\(UUID().uuidString)")!),
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

    /// blocker 1-(b): 소스가 복사만 허용한 드래그를 같은 볼륨이라는 이유로 이동시키면 안 된다.
    func testList_acceptDrop_whenSourceAllowsCopyOnly_executesCopy() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "owned-by-other-app.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [(urls: [URL], destination: URL, kind: FileOperationKind)] = []
        let coordinator = makeListCoordinator(currentDirectory: destination) { urls, dest, kind in
            executed.append((urls, dest, kind))
        }
        let info = MockDraggingInfo(urls: [source], sourceMask: .copy)

        let badge = coordinator.tableView(
            coordinator.tableView!, validateDrop: info, proposedRow: -1, proposedDropOperation: .above
        )
        let accepted = coordinator.tableView(
            coordinator.tableView!, acceptDrop: info, row: -1, dropOperation: .above
        )

        XCTAssertEqual(badge, .copy, "복사만 허용된 드래그에 이동 배지를 띄우면 안 된다")
        XCTAssertTrue(accepted)
        XCTAssertEqual(executed.count, 1)
        XCTAssertEqual(
            executed.first?.kind, .copy,
            "소스가 허용하지 않은 이동을 실행하면 파일을 소유한 앱 아래에서 원본이 사라진다(blocker 1-(b))"
        )
    }

    /// blocker 1-(a): 배지로 보여준 판정이 그대로 실행되어야 한다.
    /// 사용자가 Option을 마우스 버튼보다 **먼저** 뗀 상황을 마스크 변화로 재현한다.
    func testList_acceptDrop_afterModifierReleasedBeforeMouseButton_keepsValidatedCopy() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeListCoordinator(currentDirectory: destination) { _, _, kind in
            executed.append(kind)
        }

        // 1) Option을 누른 채 드래그 중 — AppKit이 마스크를 `.copy`로 걸러 준다("복사" 배지)
        let info = MockDraggingInfo(urls: [source], sourceMask: .copy)
        let badge = coordinator.tableView(
            coordinator.tableView!, validateDrop: info, proposedRow: -1, proposedDropOperation: .above
        )
        XCTAssertEqual(badge, .copy)

        // 2) 손가락이 Option에서 먼저 떨어진 뒤 버튼이 떨어진다 — 마스크가 원래대로 돌아온다
        info.draggingSourceOperationMask = [.copy, .move]
        _ = coordinator.tableView(coordinator.tableView!, acceptDrop: info, row: -1, dropOperation: .above)

        XCTAssertEqual(
            executed, [.copy],
            "사용자가 '복사' 배지를 보고 놓았는데 이동이 실행되면 원본이 사라진다(blocker 1-(a))"
        )
    }

    /// 기존 기본값 회귀 방지 — 수식키 없는 같은 볼륨 드롭은 여전히 이동이다.
    func testList_acceptDrop_withUnfilteredMask_onSameVolume_stillMoves() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeListCoordinator(currentDirectory: destination) { _, _, kind in
            executed.append(kind)
        }
        let info = MockDraggingInfo(urls: [source], sourceMask: [.copy, .move])

        let badge = coordinator.tableView(
            coordinator.tableView!, validateDrop: info, proposedRow: -1, proposedDropOperation: .above
        )
        _ = coordinator.tableView(coordinator.tableView!, acceptDrop: info, row: -1, dropOperation: .above)

        XCTAssertEqual(badge, .move)
        XCTAssertEqual(executed, [.move], "같은 볼륨 기본 동작(이동)이 죽으면 안 된다(B13)")
    }

    /// 이동·복사 어느 쪽도 허용되지 않은 드래그(링크 전용 등)는 아예 받지 않는다.
    func testList_dropWithoutCopyOrMovePermission_isRejected() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeListCoordinator(currentDirectory: destination) { _, _, kind in
            executed.append(kind)
        }
        let info = MockDraggingInfo(urls: [source], sourceMask: .link)

        let badge = coordinator.tableView(
            coordinator.tableView!, validateDrop: info, proposedRow: -1, proposedDropOperation: .above
        )
        let accepted = coordinator.tableView(
            coordinator.tableView!, acceptDrop: info, row: -1, dropOperation: .above
        )

        XCTAssertEqual(badge, [], "이동·복사가 모두 금지된 드래그에 배지를 띄우면 안 된다")
        XCTAssertFalse(accepted)
        XCTAssertTrue(executed.isEmpty)
    }

    /// 대상이 바뀌면 이전 판정을 재사용하지 않는다(캐시가 엉뚱한 폴더에 적용되면 안 된다).
    func testList_acceptDrop_onDifferentDestination_repolicies() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let first = try Fixture.makeDirectory(in: testRoot, name: "first")
        let second = try Fixture.makeDirectory(in: testRoot, name: "second")
        var executed: [(destination: URL, kind: FileOperationKind)] = []
        let coordinator = makeListCoordinator(currentDirectory: first) { _, dest, kind in
            executed.append((dest, kind))
        }

        // "first" 위에서 복사로 판정된 뒤
        let info = MockDraggingInfo(urls: [source], sourceMask: .copy)
        _ = coordinator.tableView(
            coordinator.tableView!, validateDrop: info, proposedRow: -1, proposedDropOperation: .above
        )

        // 실제로는 "second"에 놓였다 — 이번엔 마스크가 이동만 허용한다
        coordinator.parent.currentDirectory = second
        info.draggingSourceOperationMask = .move
        _ = coordinator.tableView(coordinator.tableView!, acceptDrop: info, row: -1, dropOperation: .above)

        XCTAssertEqual(executed.count, 1)
        XCTAssertEqual(executed.first.map { PathKey.key($0.destination) }, PathKey.key(second))
        XCTAssertEqual(executed.first?.kind, .move, "대상이 다르면 이전 판정을 재사용하면 안 된다")
    }

    // MARK: - 트리 브릿지 (SidebarTreeBridge) — 목록과 같은 규칙이어야 한다

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

    func testTree_acceptDrop_whenSourceAllowsCopyOnly_executesCopy() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "owned-by-other-app.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeTreeCoordinator { _, _, kind in executed.append(kind) }
        let node = folderNode(destination)
        let info = MockDraggingInfo(urls: [source], sourceMask: .copy)

        let badge = coordinator.outlineView(
            coordinator.outlineView!, validateDrop: info, proposedItem: node, proposedChildIndex: NSOutlineViewDropOnItemIndex
        )
        let accepted = coordinator.outlineView(
            coordinator.outlineView!, acceptDrop: info, item: node, childIndex: NSOutlineViewDropOnItemIndex
        )

        XCTAssertEqual(badge, .copy)
        XCTAssertTrue(accepted)
        XCTAssertEqual(executed, [.copy], "트리도 목록과 같은 규칙이어야 한다(목록→트리 / 트리→트리 일관성)")
    }

    func testTree_acceptDrop_afterModifierReleasedBeforeMouseButton_keepsValidatedCopy() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeTreeCoordinator { _, _, kind in executed.append(kind) }
        let node = folderNode(destination)

        let info = MockDraggingInfo(urls: [source], sourceMask: .copy)
        let badge = coordinator.outlineView(
            coordinator.outlineView!, validateDrop: info, proposedItem: node, proposedChildIndex: NSOutlineViewDropOnItemIndex
        )
        XCTAssertEqual(badge, .copy)

        info.draggingSourceOperationMask = [.copy, .move]
        _ = coordinator.outlineView(
            coordinator.outlineView!, acceptDrop: info, item: node, childIndex: NSOutlineViewDropOnItemIndex
        )

        XCTAssertEqual(executed, [.copy], "트리에서도 배지와 실제 동작이 어긋나면 안 된다(blocker 1-(a))")
    }

    func testTree_acceptDrop_withUnfilteredMask_onSameVolume_stillMoves() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeTreeCoordinator { _, _, kind in executed.append(kind) }
        let node = folderNode(destination)
        let info = MockDraggingInfo(urls: [source], sourceMask: [.copy, .move])

        _ = coordinator.outlineView(
            coordinator.outlineView!, validateDrop: info, proposedItem: node, proposedChildIndex: NSOutlineViewDropOnItemIndex
        )
        _ = coordinator.outlineView(
            coordinator.outlineView!, acceptDrop: info, item: node, childIndex: NSOutlineViewDropOnItemIndex
        )

        XCTAssertEqual(executed, [.move])
    }

    func testTree_dropWithoutCopyOrMovePermission_isRejected() throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        var executed: [FileOperationKind] = []
        let coordinator = makeTreeCoordinator { _, _, kind in executed.append(kind) }
        let node = folderNode(destination)
        let info = MockDraggingInfo(urls: [source], sourceMask: .link)

        let badge = coordinator.outlineView(
            coordinator.outlineView!, validateDrop: info, proposedItem: node, proposedChildIndex: NSOutlineViewDropOnItemIndex
        )
        let accepted = coordinator.outlineView(
            coordinator.outlineView!, acceptDrop: info, item: node, childIndex: NSOutlineViewDropOnItemIndex
        )

        XCTAssertEqual(badge, [])
        XCTAssertFalse(accepted)
        XCTAssertTrue(executed.isEmpty)
    }

    // MARK: - 판정 캐시 자체

    func testDropDecision_recallsOnlyForTheSameDestination() throws {
        let first = try Fixture.makeDirectory(in: testRoot, name: "first")
        let second = try Fixture.makeDirectory(in: testRoot, name: "second")
        var decision = DragDropPolicy.DropDecision()

        XCTAssertNil(decision.recall(destination: first), "기록 전에는 되찾을 판정이 없다")

        decision.record(.copy, destination: first)
        XCTAssertEqual(decision.recall(destination: first), .copy)
        // 폴더 URL의 후행 슬래시 표기 차이로 판정이 어긋나면 안 된다(URL 표기 정합 규칙)
        XCTAssertEqual(decision.recall(destination: URL(fileURLWithPath: first.path)), .copy)
        XCTAssertNil(decision.recall(destination: second))

        decision.clear()
        XCTAssertNil(decision.recall(destination: first))
    }
}
