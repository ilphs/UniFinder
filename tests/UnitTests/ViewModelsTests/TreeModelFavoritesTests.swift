import XCTest
@testable import UniFinder

/// 즐겨찾기 트리 반영 (`TreeModel` × `AppSettings`) — 2026-08-18 사용자 요청 B단계.
///
/// 저장소 자체의 규약(시딩·중복·유령 경로 보존)은 `AppSettingsFavoritesTests`가 담당하고,
/// 여기서는 **트리에 어떻게 나타나는지**만 본다.
@MainActor
final class TreeModelFavoritesTests: TempDirectoryTestCase {

    /// 테스트마다 새 suite를 만들고 teardown에서 지운다.
    ///
    /// `setUpWithError`/`tearDownWithError`는 nonisolated 오버라이드라 `@MainActor` 저장 프로퍼티를
    /// 건드릴 수 없다(Swift 5 targeted 동시성 진단). 그래서 상태를 들고 있지 않고
    /// **각 테스트가 필요할 때 만들어 쓰는** 방식으로 둔다.
    private func makeDefaults() -> UserDefaults {
        let name = "com.unifinder.tests.treefavorites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    /// 시딩된 기본 3개를 비운 상태의 격리 설정 — 테스트가 실제 홈 폴더 구성에 흔들리지 않게 한다.
    private func makeEmptySettings() -> AppSettings {
        let settings = AppSettings(defaults: makeDefaults())
        for url in settings.favoriteURLs {
            settings.removeFavorite(url)
        }
        return settings
    }

    private func favoritesSection(_ model: TreeModel) throws -> TreeNode {
        let section = try XCTUnwrap(model.sections.first { $0.sectionKind == .favorites })
        return section
    }

    private func favoriteNames(_ model: TreeModel) throws -> [String] {
        try favoritesSection(model).children?.map(\.name) ?? []
    }

    // MARK: - 저장소 → 트리

    func testRebuildSections_showsStoredFavoritesInOrder() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let b = try Fixture.makeDirectory(in: testRoot, name: "Bravo")
        let settings = makeEmptySettings()
        settings.addFavorite(a)
        settings.addFavorite(b)

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)

        XCTAssertEqual(try favoriteNames(model), ["Alpha", "Bravo"], "저장소 순서대로 표시되지 않음")
    }

    func testAddFavorite_thenRebuild_appearsInTree() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let settings = makeEmptySettings()
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)
        XCTAssertEqual(try favoriteNames(model), [])

        settings.addFavorite(a)
        model.rebuildSections()

        XCTAssertEqual(try favoriteNames(model), ["Alpha"])
        XCTAssertNotNil(model.node(for: a), "즐겨찾기 노드가 인덱스에 등록되지 않음")
    }

    func testRemoveFavorite_thenRebuild_disappearsFromTree() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let b = try Fixture.makeDirectory(in: testRoot, name: "Bravo")
        let settings = makeEmptySettings()
        settings.addFavorite(a)
        settings.addFavorite(b)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)

        settings.removeFavorite(a)
        model.rebuildSections()

        XCTAssertEqual(try favoriteNames(model), ["Bravo"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "즐겨찾기 해제가 실제 폴더를 지웠다")
    }

    /// 유령 경로 정책: 저장소에는 남기고 **표시에서만** 제외한다.
    /// (외장 볼륨이 잠깐 빠진 경우 등록을 잃으면 복구 수단이 없다)
    func testRebuildSections_ghostPath_isHiddenButKeptInStore() throws {
        let alive = try Fixture.makeDirectory(in: testRoot, name: "Alive")
        let ghost = try Fixture.makeDirectory(in: testRoot, name: "Ghost")
        let settings = makeEmptySettings()
        settings.addFavorite(alive)
        settings.addFavorite(ghost)

        try FileManager.default.removeItem(at: ghost)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)

        XCTAssertEqual(try favoriteNames(model), ["Alive"], "사라진 경로가 트리에 남았다")
        XCTAssertTrue(settings.isFavorite(ghost), "표시에서 제외했다고 저장소에서까지 지우면 안 된다")

        // 볼륨이 돌아온 상황 재현 — 다시 만들면 재구성만으로 복귀해야 한다.
        try FileManager.default.createDirectory(at: ghost, withIntermediateDirectories: true)
        model.rebuildSections()
        XCTAssertEqual(try favoriteNames(model), ["Alive", "Ghost"], "경로가 돌아왔는데 즐겨찾기가 복귀하지 않았다")
    }

    /// 폴더가 아닌 항목(파일)은 즐겨찾기로 표시되지 않는다.
    func testRebuildSections_filePath_isNotShown() throws {
        let file = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let settings = makeEmptySettings()
        settings.addFavorite(file)

        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)

        XCTAssertEqual(try favoriteNames(model), [], "파일이 즐겨찾기 트리에 나타났다")
    }

    // MARK: - 보호 가드 회귀 (즐겨찾기 편집과 무관해야 한다)

    /// **회귀 방지**: 즐겨찾기 항목이 편집 가능해졌어도 `isProtectedNode`는 그대로여야 한다.
    /// (즐겨찾기 "해제"는 목록에서 빼는 것이고, rename/삭제 금지와는 별개 개념이다)
    func testFavoriteNode_remainsProtectedAgainstRenameAndDelete() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let settings = makeEmptySettings()
        settings.addFavorite(a)
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: settings)

        let node = try XCTUnwrap(favoritesSection(model).children?.first)
        XCTAssertTrue(model.isProtectedNode(node), "즐겨찾기 항목의 rename/삭제 가드가 풀렸다")
        XCTAssertTrue(node.isFavoriteEntry)

        // 2026-08-18: 여기서 끝내던 것이 `parent` 끊김 회귀를 놓친 원인이다 — 모델을 한 번만
        // 만들면 `makeOrReuseFolderNode`의 **재사용 분기를 아예 타지 않는다**. 실사용에서는
        // 즐겨찾기 추가/해제가 매번 재구성을 부르므로 재구성 뒤에도 가드가 살아 있어야 한다.
        // (재연결 규약 자체는 `TreeNodeReattachTests`가 본다)
        model.rebuildSections()
        model.rebuildSections()
        let reused = try XCTUnwrap(favoritesSection(model).children?.first)
        XCTAssertTrue(reused === node, "재사용 분기를 타지 않아 회귀 검증이 무의미해졌다")
        XCTAssertTrue(model.isProtectedNode(reused), "섹션 재구성 후 즐겨찾기 가드가 풀렸다")
        XCTAssertTrue(reused.isFavoriteEntry, "재구성 후 즐겨찾기 항목 판정이 뒤집혔다")
    }

    /// 섹션 종류는 **이름 문자열이 아니라 `sectionKind`**로 식별된다 (C단계 아이콘 매핑의 전제).
    func testSections_carrySectionKind() throws {
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: makeEmptySettings())

        XCTAssertEqual(model.sections.map(\.sectionKind), [.favorites, .home, .volumes])
    }

    /// 섹션 재구성 카운터는 `revision`과 분리돼 있어야 한다 — 볼륨 아이콘 캐시가 확장마다 버려지지 않게.
    func testSectionsRevision_advancesOnlyOnRebuild() async throws {
        _ = try Fixture.makeDirectory(in: testRoot, name: "Child")
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: makeEmptySettings())
        let before = model.sectionsRevision

        let homeRoot = try XCTUnwrap(model.node(for: testRoot))
        await model.expand(homeRoot)

        XCTAssertEqual(model.sectionsRevision, before, "노드 확장만으로 섹션 재구성 카운터가 올라갔다")

        model.rebuildSections()
        XCTAssertEqual(model.sectionsRevision, before + 1)
    }
}
