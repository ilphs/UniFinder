import XCTest
@testable import UniFinder

/// 섹션 재구성이 반복돼도 **재사용 노드의 `parent`가 살아 있어야 한다** — 2026-08-18 회귀 수정.
///
/// 실측 증상: 즐겨찾기를 추가하니 사이드바 Volumes의 디스크 아이콘이 파란 폴더 아이콘으로
/// 바뀌고 복구되지 않았다. 원인은 `makeOrReuseFolderNode`가 옛 인덱스에서 되살린 노드를
/// **새 섹션 노드에 다시 잇지 않은 것**이다. `parent`는 `weak`이라, 옛 섹션 노드가 해제되는
/// 순간 `nil`이 되고 `isVolumeRoot`/`isFavoriteEntry` 같은 부모 기반 판정이 통째로 뒤집힌다.
///
/// **기존 테스트가 못 잡은 이유**: 모델을 한 번만 만들고 끝나 `makeOrReuseFolderNode`의
/// **재사용 분기를 아예 타지 않았다**. 그래서 여기서는 `rebuildSections()`를 2회 이상 돌리고,
/// 아이콘 판정(`isVolumeRoot`)과 안전 가드(`isProtectedNode`)를 **둘 다** 본다.
@MainActor
final class TreeNodeReattachTests: TempDirectoryTestCase {

    private func makeDefaults() -> UserDefaults {
        let name = "com.unifinder.tests.treereattach.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    /// 시딩된 기본 즐겨찾기를 비운 격리 설정 — 실제 홈 구성에 흔들리지 않게 한다.
    private func makeEmptySettings() -> AppSettings {
        let settings = AppSettings(defaults: makeDefaults())
        for url in settings.favoriteURLs { settings.removeFavorite(url) }
        return settings
    }

    private func section(_ model: TreeModel, _ kind: TreeNode.SectionKind) throws -> TreeNode {
        try XCTUnwrap(model.sections.first { $0.sectionKind == kind })
    }

    // MARK: - 아이콘 판정 (isVolumeRoot)

    /// 볼륨 루트는 재구성을 여러 번 거쳐도 **실제 디스크 아이콘 대상**으로 남아야 한다.
    func testRebuildSectionsTwice_volumeRootKeepsParentAndIconRole() throws {
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: makeEmptySettings())

        let firstVolumes = try section(model, .volumes).children ?? []
        XCTAssertFalse(firstVolumes.isEmpty, "볼륨 섹션이 비어 있어 회귀를 검증할 수 없다")
        let retained = firstVolumes  // 재사용 여부를 객체 동일성으로 확인하기 위해 잡아 둔다

        model.rebuildSections()
        model.rebuildSections()

        let rebuilt = try section(model, .volumes).children ?? []
        XCTAssertEqual(rebuilt.count, retained.count)
        for (index, node) in rebuilt.enumerated() {
            XCTAssertTrue(node === retained[index], "재사용 분기를 타지 않아 회귀 검증이 무의미해졌다")
            XCTAssertNotNil(node.parent, "재사용된 볼륨 노드의 parent가 끊겼다")
            XCTAssertEqual(node.parent?.sectionKind, .volumes)
            XCTAssertTrue(node.isVolumeRoot, "볼륨 루트가 공용 폴더 아이콘으로 폴백한다")
        }
    }

    /// 홈 루트도 같은 재사용 경로를 탄다.
    func testRebuildSectionsTwice_homeRootKeepsParent() throws {
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: makeEmptySettings())
        let homeRoot = try XCTUnwrap(model.node(for: testRoot))

        model.rebuildSections()
        model.rebuildSections()

        XCTAssertTrue(try XCTUnwrap(section(model, .home).children?.first) === homeRoot)
        XCTAssertEqual(homeRoot.parent?.sectionKind, .home, "홈 루트의 parent가 끊겼다")
        XCTAssertFalse(homeRoot.isVolumeRoot)
    }

    // MARK: - 안전 가드 (isProtectedNode)

    /// **가장 위험한 파급**: 경로 폴백이 없는 즐겨찾기 항목의 rename/삭제 가드.
    /// 즐겨찾기 추가/해제가 매번 `rebuildSections()`를 부르므로 실사용에서 상시로 재현된다.
    func testRebuildSectionsTwice_favoriteKeepsRenameAndDeleteGuard() throws {
        let alpha = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let settings = makeEmptySettings()
        settings.addFavorite(alpha)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)
        let node = try XCTUnwrap(section(model, .favorites).children?.first)

        // 즐겨찾기 1건 추가/해제가 실제로 만드는 재구성 횟수를 그대로 재현한다.
        model.rebuildSections()
        model.rebuildSections()

        XCTAssertTrue(try XCTUnwrap(section(model, .favorites).children?.first) === node)
        XCTAssertNotNil(node.parent, "재사용된 즐겨찾기 노드의 parent가 끊겼다")
        XCTAssertTrue(node.isFavoriteEntry)
        XCTAssertTrue(model.isProtectedNode(node), "즐겨찾기 항목의 rename/삭제 가드가 조용히 풀렸다")
    }

    /// 가드는 이제 **트리 어디에 붙어 있든** 같은 결론을 내야 한다 (토폴로지 비의존).
    /// 즐겨찾기로 등록된 폴더는 홈 트리를 펼쳐 만난 노드에서도 보호 대상이다.
    func testProtectedGuard_isTopologyIndependent() async throws {
        let alpha = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let plain = try Fixture.makeDirectory(in: testRoot, name: "Plain")
        let settings = makeEmptySettings()
        settings.addFavorite(alpha)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)

        let homeRoot = try XCTUnwrap(model.node(for: testRoot))
        await model.expand(homeRoot)
        let children = try XCTUnwrap(homeRoot.children)

        let alphaUnderHome = try XCTUnwrap(children.first { PathKey.isSame($0.url, alpha) })
        let plainUnderHome = try XCTUnwrap(children.first { PathKey.isSame($0.url, plain) })

        XCTAssertEqual(alphaUnderHome.parent?.kind, .folder, "전제 확인 — 섹션 직속이 아닌 노드여야 한다")
        XCTAssertTrue(model.isProtectedNode(alphaUnderHome), "즐겨찾기 경로가 위치에 따라 보호에서 빠졌다")
        XCTAssertFalse(model.isProtectedNode(plainUnderHome), "일반 하위 폴더까지 보호 대상이 됐다")
    }

    /// 가드의 근거 3종(홈 루트 / 볼륨 루트 / 즐겨찾기)이 **노드 없이 경로만으로도** 성립한다.
    func testProtectedURL_coversHomeVolumeAndFavorite() throws {
        let alpha = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let plain = try Fixture.makeDirectory(in: testRoot, name: "Plain")
        let settings = makeEmptySettings()
        settings.addFavorite(alpha)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)

        XCTAssertTrue(model.isProtectedURL(testRoot), "홈 루트")
        XCTAssertTrue(model.isProtectedURL(URL(fileURLWithPath: "/")), "볼륨 루트")
        XCTAssertTrue(model.isProtectedURL(alpha), "즐겨찾기 등록 경로")
        XCTAssertFalse(model.isProtectedURL(plain))

        // 즐겨찾기를 해제하면 그 즉시 보호에서 빠진다(저장소가 유일한 권위).
        settings.removeFavorite(alpha)
        XCTAssertFalse(model.isProtectedURL(alpha))
    }

    // MARK: - 소유권 (parent는 weak을 유지해야 한다)

    /// `parent`를 strong으로 바꾸면 `children`(strong 배열)과 순환 참조가 생겨 트리가 통째로 샌다.
    /// 재연결 수정이 소유권을 건드리지 않았음을 여기서 못 박는다.
    func testTreeNodes_deallocateWhenModelIsReleased() throws {
        weak var weakSection: TreeNode?
        weak var weakChild: TreeNode?

        try autoreleasepool {
            let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: makeEmptySettings())
            let home = try section(model, .home)
            weakSection = home
            weakChild = try XCTUnwrap(home.children?.first)
            model.rebuildSections()
        }

        XCTAssertNil(weakSection, "섹션 노드가 해제되지 않았다 — parent가 strong으로 바뀌었을 가능성")
        XCTAssertNil(weakChild, "재사용 노드가 해제되지 않았다 — 부모↔자식 순환 참조")
    }
}
