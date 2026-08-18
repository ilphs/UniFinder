import XCTest
@testable import UniFinder

/// 좌/우 pane 대조 테스트 — 같은 심볼릭 링크 폴더를 **트리 선택**으로 열 때와
/// **목록 더블클릭**으로 열 때 결과가 같아야 한다 (2026-08-18 회귀).
///
/// **왜 이 대조가 방어선인가**: 원래 버그는 "좌/우 동작 비대칭"으로 드러났다.
/// 우측 pane은 `AppModel.open(_:)` → `resolveTarget(of:)`가 링크를 먼저 해석해 정상 진입했지만,
/// 좌측 트리는 해석 단계 없이 미해석 `node.url`을 `navigate(to:source:.tree)`에 그대로 넘겨
/// `DirectoryLoader.list`에서 `.notADirectory`("Not a Folder")로 떨어졌다.
/// 두 진입점을 각각 따로 검증하는 테스트만으로는 이 비대칭이 드러나지 않는다.
@MainActor
final class SymlinkNavigationParityTests: TempDirectoryTestCase {

    private func makeAppModel(startURL: URL) -> AppModel {
        AppModel(
            settings: AppSettings(
                defaults: UserDefaults(suiteName: "SymlinkNavigationParity-\(UUID().uuidString)")!
            ),
            loader: DirectoryLoader(),
            startURL: startURL
        )
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// `revision`은 load 시작 시 +1, 완료(성공/실패) 시 +1 된다. 빈 폴더에서도 완료를 판정할 수 있다.
    private func waitForLoadCompletion(_ model: AppModel, after revisionBefore: Int) async {
        await waitUntil { model.directory.revision > revisionBefore + 1 }
    }

    /// 링크 폴더 fixture: `link -> target`, 타겟 안에 파일 1 + 하위 폴더 1.
    private func makeSymlinkedFolder() throws -> (link: URL, target: URL, contents: [String]) {
        let target = try Fixture.makeDirectory(in: testRoot, name: "target")
        try Fixture.makeFile(in: target, name: "inside.txt")
        _ = try Fixture.makeDirectory(in: target, name: "nested")
        let link = try Fixture.makeSymlink(in: testRoot, name: "link", destination: target)
        return (link, target, ["inside.txt", "nested"])
    }

    // MARK: - 좌/우 대조

    func testTreeSelectionAndListOpen_onSameSymlinkFolder_produceSameResult() async throws {
        let fixture = try makeSymlinkedFolder()

        // (좌) 트리 선택 경로 — SidebarTreeBridge의 onSelect가 하는 일 그대로:
        //     미해석 노드 URL을 navigate(to:source:.tree)에 넘긴다.
        let treeModel = makeAppModel(startURL: testRoot)
        let treeRevision = treeModel.directory.revision
        treeModel.navigate(to: fixture.link, source: .tree)
        await waitForLoadCompletion(treeModel, after: treeRevision)

        // (우) 목록 더블클릭 경로 — AppModel.open(_:)
        let listModel = makeAppModel(startURL: testRoot)
        let listRevision = listModel.directory.revision
        let linkItem = try await loadedItem(named: "link", in: testRoot)
        XCTAssertTrue(linkItem.isSymlink, "fixture 전제: 목록 항목이 심볼릭 링크로 인식되어야 함")
        XCTAssertTrue(linkItem.isDirectory, "fixture 전제: 심볼릭 링크가 폴더로 인식되어야 함")
        listModel.open([linkItem])
        await waitForLoadCompletion(listModel, after: listRevision)

        // 1) 어느 쪽도 에러가 없어야 한다 (버그 당시 트리 경로만 .notADirectory였다)
        XCTAssertNil(
            treeModel.directory.error,
            "트리 선택으로 심볼릭 링크 폴더를 열 수 없다: \(String(describing: treeModel.directory.error))"
        )
        XCTAssertNil(listModel.directory.error)

        // 2) 두 경로가 같은 내용을 보여야 한다
        XCTAssertEqual(treeModel.directory.items.map(\.name).sorted(), fixture.contents)
        XCTAssertEqual(
            treeModel.directory.items.map(\.name).sorted(),
            listModel.directory.items.map(\.name).sorted(),
            "좌/우 진입점이 서로 다른 내용을 보여주면 안 된다"
        )
    }

    /// 트리 경로는 사용자가 고른 **링크 경로 표기**를 유지해야 한다(주소창/트리 선택 정합).
    /// 목록 더블클릭은 설계서 §6대로 타겟으로 이동한다 — 표기는 달라도 둘 다 성공해야 한다는 것이 규약.
    func testTreeSelection_keepsLinkPath_whileListOpenResolvesToTarget() async throws {
        let fixture = try makeSymlinkedFolder()

        let treeModel = makeAppModel(startURL: testRoot)
        let treeRevision = treeModel.directory.revision
        treeModel.navigate(to: fixture.link, source: .tree)
        await waitForLoadCompletion(treeModel, after: treeRevision)

        XCTAssertEqual(
            treeModel.navigation.currentURL.path, fixture.link.path,
            "트리 선택은 링크 표기를 유지해야 한다(TreeModel.canonicalDirectoryURL이 링크를 해석하지 않는 설계와 정합)"
        )
        XCTAssertNil(treeModel.directory.error)

        let listModel = makeAppModel(startURL: testRoot)
        let listRevision = listModel.directory.revision
        let linkItem = try await loadedItem(named: "link", in: testRoot)
        listModel.open([linkItem])
        await waitForLoadCompletion(listModel, after: listRevision)

        XCTAssertEqual(
            listModel.navigation.currentURL.path,
            fixture.target.resolvingSymlinksInPath().path,
            "더블클릭은 타겟으로 이동한다(설계서 §6)"
        )
        XCTAssertNil(listModel.directory.error)
    }

    /// 트리 확장(좌측) → 이동 → reveal 왕복까지 한 번에. 확장된 링크 노드가 회색으로 남으면 안 된다.
    func testTreeExpandThenNavigate_onSymlinkFolder_selectsNodeWithoutError() async throws {
        let fixture = try makeSymlinkedFolder()

        let model = makeAppModel(startURL: testRoot)
        let tree = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let homeRoot = tree.node(for: testRoot) else {
            return XCTFail("홈 루트 노드를 찾을 수 없음")
        }
        await tree.expand(homeRoot)
        guard let linkNode = homeRoot.children?.first(where: { $0.name == "link" }) else {
            return XCTFail("심볼릭 링크 폴더가 트리에 없음")
        }
        await tree.expand(linkNode)
        XCTAssertTrue(linkNode.isAccessible, "확장한 링크 노드가 비접근(회색)으로 남으면 안 됨")
        XCTAssertEqual(linkNode.children?.map(\.name), ["nested"])

        let revisionBefore = model.directory.revision
        model.navigate(to: linkNode.url, source: .tree)
        await waitForLoadCompletion(model, after: revisionBefore)

        XCTAssertNil(model.directory.error)
        XCTAssertEqual(model.directory.items.map(\.name).sorted(), fixture.contents)

        await tree.reveal(model.navigation.currentURL)
        XCTAssertEqual(tree.selectedURL?.path, fixture.link.path)
    }

    /// 깨진 링크를 트리에서 선택해도 크래시/행 없이 상위 폴더로 회수되어야 한다.
    func testTreeSelection_onBrokenSymlink_fallsBackToEnclosingFolder() async throws {
        let missing = testRoot.appendingPathComponent("gone", isDirectory: true)
        let broken = try Fixture.makeSymlink(in: testRoot, name: "broken", destination: missing)
        // 시작 위치를 별도 폴더로 둬야 "상위로 회수" 결과가 실제 이동으로 관측된다
        // (시작 위치가 testRoot면 회수 결과가 현재 위치와 같아 navigate가 조기 반환한다).
        let start = try Fixture.makeDirectory(in: testRoot, name: "start")

        let model = makeAppModel(startURL: start)
        let revisionBefore = model.directory.revision
        model.navigate(to: broken, source: .tree)
        await waitForLoadCompletion(model, after: revisionBefore)

        // 존재하지 않는 대상이므로 `nearestExistingDirectory`가 상위(testRoot)로 되돌린다.
        XCTAssertEqual(model.navigation.currentURL.path, testRoot.path)
        XCTAssertNil(model.directory.error)
    }

    /// 순환 링크도 무한 루프 없이 유한 시간에 처리되어야 한다.
    func testTreeSelection_onCyclicSymlink_terminatesWithoutHanging() async throws {
        let a = testRoot.appendingPathComponent("cycleA")
        let b = testRoot.appendingPathComponent("cycleB")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
        let start = try Fixture.makeDirectory(in: testRoot, name: "start")

        let model = makeAppModel(startURL: start)
        let revisionBefore = model.directory.revision
        model.navigate(to: a, source: .tree)
        await waitForLoadCompletion(model, after: revisionBefore)

        XCTAssertEqual(model.navigation.currentURL.path, testRoot.path)
    }

    // MARK: - 헬퍼

    /// 실제 목록 열거를 거쳐 만들어진 `FileItem`을 가져온다
    /// (더블클릭 경로는 브릿지가 넘겨주는 `FileItem`을 쓰므로, 손으로 만든 값이 아니라
    ///  로더가 만든 값이어야 `isSymlink`/`isDirectory` 판정까지 함께 검증된다).
    private func loadedItem(named name: String, in directory: URL) async throws -> FileItem {
        let items = try await DirectoryLoader().list(at: directory, showHidden: false)
        return try XCTUnwrap(items.first(where: { $0.name == name }), "fixture 항목 \(name)을 찾을 수 없음")
    }
}
