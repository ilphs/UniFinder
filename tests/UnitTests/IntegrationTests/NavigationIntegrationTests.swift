import XCTest
@testable import UniFinder

/// 통합 테스트: 이동 4수단(트리 선택/더블클릭 진입/주소창 입력/히스토리 뒤로-앞으로) 교차 사용 후
/// `NavigationModel.currentURL` · `DirectoryModel.items` · `TreeModel` 선택 상태가 일치하는지 검증.
/// (AppKit 브릿지 자체는 XCUITest 스모크(§4.4)에서 별도 검증 — 여기서는 ViewModel 레이어를 통해
///  4가지 진입 지점을 시뮬레이션한다: 트리 선택→navigate, 더블클릭→navigate, 주소창 입력→navigate,
///  히스토리→goBack/goForward. 설계서 §3.3 흐름을 그대로 모델 레벨에서 재현한다.)
@MainActor
final class NavigationIntegrationTests: TempDirectoryTestCase {

    private func makeStack(rootChildren: [String]) throws -> (
        nav: NavigationModel,
        dir: DirectoryModel,
        tree: TreeModel,
        childURLs: [String: URL]
    ) {
        var childURLs: [String: URL] = [:]
        for name in rootChildren {
            childURLs[name] = try Fixture.makeDirectory(in: testRoot, name: name)
        }
        let loader = DirectoryLoader()
        let nav = NavigationModel(startURL: testRoot)
        let dir = DirectoryModel(loader: loader)
        let tree = TreeModel(loader: loader, homeURL: testRoot)
        return (nav, dir, tree, childURLs)
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 4수단 중 하나로 "이동"을 수행하고 세 모델의 상태 일치를 검증하는 공통 어서션.
    private func assertConsistentState(
        nav: NavigationModel,
        dir: DirectoryModel,
        tree: TreeModel,
        expected url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // NavigationModel/TreeModel은 각자 내부적으로 URL을 정규화한다(trailing slash 유무 등
        // 표기 방식이 다를 수 있음 — 실제 프로덕션 규약). 경로 문자열(.path) 기준으로 비교해
        // 그 표기 차이에 테스트가 결합되지 않게 한다.
        XCTAssertEqual(nav.currentURL.path, url.path, "NavigationModel.currentURL 불일치", file: file, line: line)

        // `!dir.isLoading` 대기는 무효였다 — isLoading은 200ms를 넘긴 로드에만 true가 되므로
        // 짧은 로드에서는 조건이 즉시 참이 되어 뒤따르는 어서션이 "로드 완료 전"에 평가됐다.
        // revision은 load() 시작 시 +1, 완료(성공/실패) 시 +1 되므로 완료 신호로 쓸 수 있다.
        // (빈 폴더 fixture라 items로는 완료를 판정할 수 없다)
        let revisionBeforeLoad = dir.revision
        dir.load(url: url)
        await waitUntil { dir.revision > revisionBeforeLoad + 1 }

        XCTAssertGreaterThan(
            dir.revision, revisionBeforeLoad + 1,
            "로드가 완료되기 전에 어서션이 평가됨(대기 조건이 실제 완료를 검증하지 못함)",
            file: file, line: line
        )
        XCTAssertEqual(dir.currentURL?.path, url.path, "DirectoryModel.currentURL 불일치", file: file, line: line)
        XCTAssertNil(dir.error, "예상치 못한 로드 에러", file: file, line: line)

        await tree.reveal(url)
        guard let node = tree.node(for: url) else {
            return XCTFail("TreeModel에 해당 경로 노드가 없음(reveal 실패)", file: file, line: line)
        }
        XCTAssertEqual(node.url.path, url.path, file: file, line: line)
    }

    func testCrossMeans_treeSelection_thenAddressBar_thenDoubleClick_thenHistory_stateStaysConsistent() async throws {
        let (nav, dir, tree, urls) = try makeStack(rootChildren: ["docs", "src", "assets"])
        guard let docs = urls["docs"], let src = urls["src"], let assets = urls["assets"] else {
            return XCTFail("fixture 생성 실패")
        }

        // 1) 트리 선택 시뮬레이션: 선택 → NavigationModel.navigate
        nav.navigate(to: docs)
        await assertConsistentState(nav: nav, dir: dir, tree: tree, expected: docs)

        // 2) 주소창 직접 입력 시뮬레이션
        nav.navigate(to: src)
        await assertConsistentState(nav: nav, dir: dir, tree: tree, expected: src)

        // 3) 더블클릭 진입 시뮬레이션(우측 목록에서 폴더 더블클릭 → navigate)
        nav.navigate(to: assets)
        await assertConsistentState(nav: nav, dir: dir, tree: tree, expected: assets)

        // 4) 히스토리 뒤로/앞으로
        nav.goBack()
        await assertConsistentState(nav: nav, dir: dir, tree: tree, expected: src)

        nav.goBack()
        await assertConsistentState(nav: nav, dir: dir, tree: tree, expected: docs)

        nav.goForward()
        await assertConsistentState(nav: nav, dir: dir, tree: tree, expected: src)

        // 새 이동 후 forward 클리어까지 함께 확인
        nav.navigate(to: assets)
        XCTAssertTrue(nav.forwardStack.isEmpty)
        await assertConsistentState(nav: nav, dir: dir, tree: tree, expected: assets)
    }

    func testCrossMeans_directoryModelReflectsCurrentTargetContents() async throws {
        let (nav, dir, tree, urls) = try makeStack(rootChildren: ["docs"])
        guard let docs = urls["docs"] else { return XCTFail("fixture 생성 실패") }
        try Fixture.makeFile(in: docs, name: "readme.txt")
        try Fixture.makeFile(in: docs, name: "notes.md")

        nav.navigate(to: docs)
        dir.load(url: nav.currentURL)
        await waitUntil { !dir.items.isEmpty }

        XCTAssertEqual(dir.items.map(\.name).sorted(), ["notes.md", "readme.txt"])

        await tree.reveal(docs)
        XCTAssertEqual(tree.node(for: docs)?.url.path, docs.path)
    }
}
