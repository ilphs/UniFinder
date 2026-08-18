import XCTest
@testable import UniFinder

/// `TreeModel` 단위 테스트.
/// 대상(T4 수용 기준): lazy 1-depth 확장, reveal 경로 체인,
/// 순환 심볼릭 depth 상한(32), 접근 불가 노드.
///
/// `TreeModel`은 섹션 3개(즐겨찾기/홈/볼륨)를 가지며, "홈" 섹션의 루트 폴더 노드는
/// `homeURL`로 지정한 경로다(`TreeModel.init(loader:homeURL:showHidden:)`).
/// 테스트에서는 `homeURL: testRoot`로 주입해 홈 트리 전체를 임시 디렉토리 아래로 격리한다.
@MainActor
final class TreeModelTests: TempDirectoryTestCase {

    /// "홈" 섹션 아래 루트 폴더 노드(= testRoot 자신)를 찾는다.
    private func homeRootNode(_ model: TreeModel) -> TreeNode? {
        model.node(for: testRoot)
    }

    // MARK: - lazy 1-depth 확장

    func testExpand_loadsOnlyImmediateChildren_notGrandchildren() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let b = try Fixture.makeDirectory(in: a, name: "B")
        _ = try Fixture.makeDirectory(in: b, name: "C")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else {
            return XCTFail("홈 루트 노드를 찾을 수 없음")
        }

        await model.expand(homeRoot)
        guard let nodeA = homeRoot.children?.first(where: { $0.name == "A" }) else {
            return XCTFail("A 노드가 홈 하위에 없음")
        }
        XCTAssertNil(nodeA.children, "확장 전에는 children이 로드되지 않아야 함(lazy)")

        await model.expand(nodeA)

        XCTAssertNotNil(nodeA.children)
        XCTAssertEqual(nodeA.children?.map(\.name), ["B"])
        guard let nodeB = nodeA.children?.first else {
            return XCTFail("B 노드가 없음")
        }
        XCTAssertNil(nodeB.children, "손자 노드(C)는 아직 로드되지 않아야 함")
    }

    func testExpand_alreadyLoaded_doesNotReload() async throws {
        _ = try Fixture.makeDirectory(in: testRoot, name: "A")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else {
            return XCTFail("홈 루트 노드를 찾을 수 없음")
        }
        await model.expand(homeRoot)
        let firstChildren = homeRoot.children

        // 확장 후 디스크에 폴더를 추가해도, 재확장(children != nil) 시에는 그대로 유지되어야 한다.
        _ = try Fixture.makeDirectory(in: testRoot, name: "B-added-after")
        await model.expand(homeRoot)

        XCTAssertEqual(homeRoot.children?.map(\.name), firstChildren?.map(\.name))
    }

    // MARK: - 확장 재진입 (code review 필수 수정 #2)

    /// **재현 시나리오**: `AppModel.loadCurrent()`가 이동마다 취소 없이 새 `reveal` Task를 띄우므로,
    /// 연속 이동 시 같은 노드에 대해 `expand`가 동시에 두 번 진입한다. 예전 구현에는
    /// `expandInBackground`가 가진 `!node.isLoading` 가드가 `expand`에 없어서 자식 `TreeNode`가
    /// 두 벌 생성됐고, `register`는 먼저 만든 노드를 유지하므로 `nodeIndex`가 트리에 붙어있지
    /// 않은 스테일 노드를 가리키게 됐다.
    func testExpand_concurrentReentry_doesNotCreateDuplicateNodes() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else {
            return XCTFail("홈 루트 노드를 찾을 수 없음")
        }

        async let first: Void = model.expand(homeRoot)
        async let second: Void = model.expand(homeRoot)
        _ = await (first, second)

        XCTAssertEqual(homeRoot.children?.count, 1, "중복 확장으로 자식이 두 벌 만들어지면 안 됨")
        let attached = homeRoot.children?.first(where: { $0.name == "A" })
        XCTAssertNotNil(attached)
        XCTAssertTrue(
            model.node(for: a) === attached,
            "nodeIndex가 트리에 붙어있지 않은 스테일 노드를 가리킴(reveal이 조용히 실패하는 원인)"
        )
    }

    /// 연속 이동으로 reveal이 중첩된 상황 그대로의 재현.
    func testConcurrentReveals_keepNodeIndexAttachedToLiveTree() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let b = try Fixture.makeDirectory(in: testRoot, name: "B")
        let a1 = try Fixture.makeDirectory(in: a, name: "A1")
        let b1 = try Fixture.makeDirectory(in: b, name: "B1")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)

        async let firstReveal: Void = model.reveal(a1)
        async let secondReveal: Void = model.reveal(b1)
        _ = await (firstReveal, secondReveal)

        guard let homeRoot = homeRootNode(model) else {
            return XCTFail("홈 루트 노드를 찾을 수 없음")
        }
        let liveA = homeRoot.children?.first(where: { $0.name == "A" })
        let liveB = homeRoot.children?.first(where: { $0.name == "B" })

        XCTAssertTrue(model.node(for: a) === liveA, "A 노드가 스테일함")
        XCTAssertTrue(model.node(for: b) === liveB, "B 노드가 스테일함")
        XCTAssertTrue(model.node(for: a1) === liveA?.children?.first(where: { $0.name == "A1" }))
        XCTAssertTrue(model.node(for: b1) === liveB?.children?.first(where: { $0.name == "B1" }))
    }

    func testReveal_cancelledBeforeStart_doesNotTouchSelection() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)

        let task = Task { await model.reveal(a) }
        task.cancel()
        await task.value

        XCTAssertNil(model.selectedURL, "취소된 reveal이 선택 상태를 갱신하면 안 됨")
        XCTAssertNil(model.consumePendingReveal())
    }

    // MARK: - reveal 경로 체인

    func testReveal_expandsEntirePathChainAndSelectsTarget() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let b = try Fixture.makeDirectory(in: a, name: "B")
        let c = try Fixture.makeDirectory(in: b, name: "C")

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        await model.reveal(c)

        guard let nodeA = model.node(for: a) else { return XCTFail("A가 확장되지 않음") }
        guard let nodeB = model.node(for: b) else { return XCTFail("B가 확장되지 않음") }
        guard let nodeC = model.node(for: c) else { return XCTFail("C가 확장되지 않음") }

        XCTAssertTrue(nodeA.isExpanded)
        XCTAssertTrue(nodeB.isExpanded)
        XCTAssertNotNil(nodeA.children)
        XCTAssertNotNil(nodeB.children)
        XCTAssertEqual(nodeC.url.standardizedFileURL.path, c.standardizedFileURL.path)

        // reveal 후 선택 대상과 브릿지가 소비할 확장 체인이 채워져 있어야 한다.
        guard let chain = model.consumePendingReveal() else {
            return XCTFail("pendingReveal 체인이 비어있음")
        }
        XCTAssertEqual(chain.last?.url.standardizedFileURL.path, c.standardizedFileURL.path)
        // 1회성 소비 — 다시 가져오면 nil
        XCTAssertNil(model.consumePendingReveal())
    }

    func testReveal_nonExistentPath_doesNotCrash() async throws {
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        let missing = testRoot.appendingPathComponent("no/such/path", isDirectory: true)
        await model.reveal(missing)
        // 크래시 없이 종료되면 성공. 존재하는 가장 가까운 조상까지만 확장되어야 한다.
        XCTAssertNotNil(model.node(for: testRoot))
    }

    // MARK: - 순환 심볼릭 depth 상한

    func testReveal_cyclicSymlink_stopsAtDepthCapAndDoesNotHang() async throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        // A 안에 자기 자신을 가리키는 심볼릭 링크(순환 구조) 생성.
        try Fixture.makeSymlink(in: a, name: "loop", destination: a)

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)

        let expectation = expectation(description: "reveal이 유한 시간 내 종료됨")
        Task {
            let deepPath = (0..<40).map { _ in "loop" }.joined(separator: "/")
            let deepURL = a.appendingPathComponent(deepPath, isDirectory: true)
            await model.reveal(deepURL)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 10.0)
        // 크래시/무한루프 없이 종료되면 성공.
    }

    // MARK: - 심볼릭 링크 폴더 노드 확장 (2026-08-18 회귀)

    /// **재현 시나리오**: `~/Dropbox`(심볼릭 링크) 노드의 디스클로저를 펼쳐도 자식이 나오지 않고
    /// 회색(비접근) 처리됐다. `performExpand`가 `loader.list(at: node.url)`을 미해석 링크 URL로
    /// 호출하는데, 예전 `DirectoryLoader`가 그 URL을 `ENOTDIR`로 거절해 catch 절의
    /// `isAccessible = false` 경로로 떨어졌기 때문(= 권한 없는 폴더와 구분되지 않았다).
    func testExpand_symlinkDirectoryNode_isAccessibleAndLoadsTargetChildren() async throws {
        let target = try Fixture.makeDirectory(in: testRoot, name: "target")
        _ = try Fixture.makeDirectory(in: target, name: "child")
        try Fixture.makeFile(in: target, name: "file.txt")
        try Fixture.makeSymlink(in: testRoot, name: "link", destination: target)

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else {
            return XCTFail("홈 루트 노드를 찾을 수 없음")
        }
        await model.expand(homeRoot)

        guard let linkNode = homeRoot.children?.first(where: { $0.name == "link" }) else {
            return XCTFail("심볼릭 링크 폴더가 트리에 폴더 노드로 나타나야 함")
        }
        XCTAssertTrue(linkNode.isSymlink)

        await model.expand(linkNode)

        XCTAssertTrue(linkNode.isAccessible, "심볼릭 링크 폴더가 비접근(회색) 노드로 처리되면 안 됨")
        XCTAssertEqual(linkNode.children?.map(\.name), ["child"], "타겟의 하위 폴더가 로드되어야 함")
        XCTAssertEqual(
            linkNode.children?.first?.url.path,
            testRoot.appendingPathComponent("link/child").path,
            "자식 노드 URL은 링크 경로 표기를 유지해야 한다(nodeIndex 키 정합)"
        )
    }

    /// 링크 경로를 통한 reveal도 체인 전개가 되어야 한다(트리 선택 → 우측 이동 → reveal 왕복).
    func testReveal_throughSymlinkDirectory_expandsChain() async throws {
        let target = try Fixture.makeDirectory(in: testRoot, name: "target")
        _ = try Fixture.makeDirectory(in: target, name: "child")
        let link = try Fixture.makeSymlink(in: testRoot, name: "link", destination: target)

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        let viaLink = link.appendingPathComponent("child", isDirectory: true)
        await model.reveal(viaLink)

        guard let node = model.node(for: viaLink) else {
            return XCTFail("링크 경유 경로의 노드를 찾을 수 없음(reveal 실패)")
        }
        XCTAssertEqual(node.url.path, viaLink.path)
        XCTAssertEqual(model.selectedURL?.path, viaLink.path)
    }

    // MARK: - 접근 불가 노드

    func testExpand_inaccessibleDirectory_marksInaccessibleWithoutCrashing() async throws {
        let (_, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "locked")
        defer { restore() }

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = homeRootNode(model) else {
            return XCTFail("홈 루트 노드를 찾을 수 없음")
        }
        await model.expand(homeRoot)

        guard let node = homeRoot.children?.first(where: { $0.name == "locked" }) else {
            return XCTFail("접근 불가 노드가 트리에 존재해야 함(선택은 못하더라도 표시는 되어야 함)")
        }
        await model.expand(node)

        XCTAssertFalse(node.isAccessible, "권한 없는 폴더는 isAccessible=false로 표시되어야 함")
        XCTAssertEqual(node.children?.count ?? 0, 0, "권한 없는 폴더 확장 시 children은 비어있어야(크래시 없이) 함")
    }
}
