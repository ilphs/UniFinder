import XCTest
@testable import UniFinder

/// `TreeModel.invalidate(_:)` (m2-impl.md T1, architect B8) 단위 테스트.
///
/// M1의 `nodeIndex`는 등록(`register`)만 있고 제거 경로가 없어서, 트리에서 이름 변경·삭제·
/// 새 폴더 생성이 일어나면 스테일 항목을 계속 가리키는 문제가 있었다.
///
/// 실제 구현(`src/ViewModels/TreeModel.swift`)의 동작:
/// 1. `url`(없으면 `PathKey.parent`를 따라 가장 가까운 인덱싱된 조상)의 노드를 찾는다
/// 2. **그 노드 자신은 인덱스에 유지**하고, 서브트리(자식 이하)의 인덱스 키만 전부 제거한다
/// 3. 진행 중인 확장을 취소하고 `children = nil`로 되돌린다
/// 4. `revision`을 올리고, 노드가 펼쳐진 상태였다면 즉시 재확장(`expandInBackground`)한다
@MainActor
final class TreeModelInvalidationTests: TempDirectoryTestCase {

    private func homeRootNode(_ model: TreeModel) -> TreeNode? {
        model.node(for: testRoot)
    }

    func testInvalidate_removesDescendantsFromIndexButKeepsTargetNodeItself() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let b = try Fixture.makeDirectory(in: a, name: "B")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else { return XCTFail("홈 루트 노드를 찾을 수 없음") }
        await model.expand(homeRoot)
        guard let nodeA = model.node(for: a) else { return XCTFail("A가 인덱스에 없음") }
        await model.expand(nodeA)
        XCTAssertNotNil(model.node(for: b), "무효화 전에는 B가 인덱스에 있어야 함")

        model.invalidate(a)

        XCTAssertTrue(model.node(for: a) === nodeA, "무효화 대상 노드 자신은 인덱스에 그대로 남아있어야 함(같은 객체)")
        XCTAssertNil(model.node(for: b), "무효화된 서브트리의 자손은 인덱스에서 제거되어야 함")
    }

    func testInvalidate_clearsChildrenSoNextExpandReloadsFreshData() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        _ = try Fixture.makeDirectory(in: a, name: "Old")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else { return XCTFail("홈 루트 노드를 찾을 수 없음") }
        await model.expand(homeRoot)
        guard let nodeA = model.node(for: a) else { return XCTFail("A가 인덱스에 없음") }
        await model.expand(nodeA)
        XCTAssertEqual(nodeA.children?.map(\.name), ["Old"])
        nodeA.isExpanded = false // 재확장 자동 트리거(펼쳐진 상태 유지 시)를 배제하고 수동으로 검증하기 위함

        // 트리 밖에서 파일시스템이 바뀐 상황을 재현(새 폴더 생성/삭제 등 파괴적 작업 이후를 흉내).
        try FileManager.default.removeItem(at: a.appendingPathComponent("Old"))
        _ = try Fixture.makeDirectory(in: a, name: "New")

        model.invalidate(a)
        XCTAssertNil(nodeA.children, "invalidate 이후 children은 nil로 되돌아가 lazy 상태가 되어야 함")

        await model.expand(nodeA)
        XCTAssertEqual(nodeA.children?.map(\.name), ["New"], "재확장 시 새 파일시스템 상태를 반영해야 함")
    }

    func testInvalidate_whenNodeWasExpanded_automaticallyReExpandsWithFreshData() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        _ = try Fixture.makeDirectory(in: a, name: "Old")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else { return XCTFail("홈 루트 노드를 찾을 수 없음") }
        await model.expand(homeRoot)
        guard let nodeA = model.node(for: a) else { return XCTFail("A가 인덱스에 없음") }
        await model.expand(nodeA)
        XCTAssertTrue(nodeA.isExpanded)

        try FileManager.default.removeItem(at: a.appendingPathComponent("Old"))
        _ = try Fixture.makeDirectory(in: a, name: "New")

        model.invalidate(a)

        // 펼쳐진 상태였던 노드는 재확장을 기다리지 않아도 자동으로 다시 로드되어야 한다.
        try await waitUntil { nodeA.children?.map(\.name) == ["New"] }
        XCTAssertEqual(nodeA.children?.map(\.name), ["New"])
    }

    func testInvalidate_incrementsRevisionSoBridgeReExpands() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else { return XCTFail("홈 루트 노드를 찾을 수 없음") }
        await model.expand(homeRoot)

        let before = model.revision
        model.invalidate(a)
        XCTAssertGreaterThan(model.revision, before, "invalidate는 브릿지 재확장 트리거를 위해 revision을 증가시켜야 함")
    }

    func testInvalidate_thenReveal_doesNotFailOnStaleIndex() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let b = try Fixture.makeDirectory(in: a, name: "B")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        await model.reveal(b)
        XCTAssertNotNil(model.node(for: b))

        model.invalidate(a)
        // invalidate 직후에도 reveal이 스테일 인덱스로 실패(잘못된 체인을 반환하거나 크래시)하지 않아야 한다.
        await model.reveal(b)

        XCTAssertNotNil(model.node(for: a), "invalidate 이후 reveal이 A를 재구성하지 못함")
        XCTAssertNotNil(model.node(for: b), "invalidate 이후 reveal이 B를 재구성하지 못함")
        XCTAssertEqual(model.selectedURL?.standardizedFileURL.path, b.standardizedFileURL.path)
    }

    /// 노드 자체가 사라지거나 이름이 바뀐 경우엔 **부모**를 무효화한다(문서화된 사용 패턴) —
    /// 그러면 그 노드가 서브트리째 인덱스에서 빠지고, 재확장 시 새 이름/구성으로 다시 만들어진다.
    func testInvalidateParent_afterChildRenamedOnDisk_rebuildsWithNewName() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "Old-Name")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else { return XCTFail("홈 루트 노드를 찾을 수 없음") }
        await model.expand(homeRoot)
        XCTAssertNotNil(model.node(for: a))

        let renamed = testRoot.appendingPathComponent("New-Name", isDirectory: true)
        try FileManager.default.moveItem(at: a, to: renamed)

        model.invalidate(testRoot) // 부모(홈 루트) 무효화
        await model.expand(homeRoot)

        XCTAssertNil(model.node(for: a), "옛 이름의 인덱스 항목은 제거되어야 함")
        XCTAssertNotNil(model.node(for: renamed), "새 이름으로 다시 인덱싱되어야 함")
        XCTAssertEqual(homeRoot.children?.map(\.name), ["New-Name"])
    }

    func testInvalidate_unknownDescendantURL_findsNearestIndexedAncestorWithoutCrashing() {
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        let neverExisted = testRoot.appendingPathComponent("never/existed/path", isDirectory: true)
        model.invalidate(neverExisted) // 크래시 없이 종료되면 성공(가장 가까운 조상 = 홈 루트로 처리됨)
        XCTAssertNotNil(model.node(for: testRoot), "홈 루트 자신은 여전히 인덱스에 있어야 함")
    }

    // MARK: - 헬퍼

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        interval: UInt64 = 10_000_000,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: interval)
        }
    }
}
