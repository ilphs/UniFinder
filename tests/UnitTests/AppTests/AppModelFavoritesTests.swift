import XCTest
@testable import UniFinder

/// 즐겨찾기 등록/해제의 앱 레벨 진입점 (`AppModel`) — 2026-08-18 사용자 요청 B단계.
///
/// UI 3곳(메뉴바 / 목록 컨텍스트 메뉴 / 트리 컨텍스트 메뉴)이 전부 이 API 하나를 경유하므로,
/// 여기서 토글 판정과 트리 반영을 검증하면 세 진입점이 함께 커버된다.
@MainActor
final class AppModelFavoritesTests: TempDirectoryTestCase {

    /// 테스트마다 새 suite를 만들고 teardown에서 지운다.
    ///
    /// `setUpWithError`/`tearDownWithError`는 nonisolated 오버라이드라 `@MainActor` 저장 프로퍼티를
    /// 건드릴 수 없다(Swift 5 targeted 동시성 진단). 그래서 상태를 들고 있지 않고
    /// **각 테스트가 필요할 때 만들어 쓰는** 방식으로 둔다.
    private func makeDefaults() -> UserDefaults {
        let name = "com.unifinder.tests.appfavorites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeModel() -> AppModel {
        let settings = AppSettings(defaults: makeDefaults())
        // 시딩된 기본 3개를 비워 실제 홈 폴더 구성에 흔들리지 않게 한다.
        for url in settings.favoriteURLs { settings.removeFavorite(url) }
        return AppModel(settings: settings, startURL: testRoot)
    }

    private func favoriteNames(_ model: AppModel) throws -> [String] {
        let section = try XCTUnwrap(model.tree.sections.first { $0.sectionKind == .favorites })
        return section.children?.map(\.name) ?? []
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 등록/해제 → 트리 반영

    func testAddFavorite_rebuildsTreeImmediately() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let model = makeModel()
        XCTAssertEqual(try favoriteNames(model), [])

        model.addFavorite(folder)

        XCTAssertTrue(model.isFavorite(folder))
        XCTAssertEqual(try favoriteNames(model), ["Alpha"], "등록 후 트리가 재구성되지 않았다")
    }

    func testRemoveFavorite_rebuildsTreeAndKeepsFolderOnDisk() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let model = makeModel()
        model.addFavorite(folder)

        model.removeFavorite(folder)

        XCTAssertFalse(model.isFavorite(folder))
        XCTAssertEqual(try favoriteNames(model), [], "해제 후 트리가 재구성되지 않았다")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.path),
            "즐겨찾기 해제가 파일시스템을 건드렸다 — 삭제와 다른 개념이라는 규약 위반"
        )
    }

    func testToggleFavorite_switchesBothDirections() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let model = makeModel()

        model.toggleFavorite(folder)
        XCTAssertTrue(model.isFavorite(folder))

        model.toggleFavorite(folder)
        XCTAssertFalse(model.isFavorite(folder))
    }

    func testAddFavorite_duplicate_doesNotDuplicateTreeNode() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let model = makeModel()

        model.addFavorite(folder)
        model.addFavorite(folder)

        XCTAssertEqual(try favoriteNames(model), ["Alpha"], "중복 등록이 트리에 두 번 나타났다")
    }

    // MARK: - 메뉴 대상 판정 (등록/해제 토글)

    /// 선택이 없으면 표시 중인 폴더가 대상이다.
    func testFavoriteTarget_withoutSelection_isCurrentDirectory() {
        let model = makeModel()

        XCTAssertEqual(
            model.favoriteTarget.map(PathKey.key),
            PathKey.key(model.navigation.currentURL)
        )
        XCTAssertFalse(model.isFavoriteTargetRegistered)
    }

    func testFavoriteTarget_singleFolderSelection_isThatFolder() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        let model = makeModel()
        model.start()
        await waitUntil { !model.directory.items.isEmpty }

        model.directory.selection = [try XCTUnwrap(model.directory.items.first { $0.name == "Alpha" }).url]

        XCTAssertEqual(model.favoriteTarget.map(PathKey.key), PathKey.key(folder))
    }

    /// 파일 선택은 대상이 없다 → 메뉴 비활성 (폴더만 즐겨찾기가 된다).
    func testFavoriteTarget_fileSelection_isNil() async throws {
        _ = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let model = makeModel()
        model.start()
        await waitUntil { !model.directory.items.isEmpty }

        model.directory.selection = [try XCTUnwrap(model.directory.items.first { $0.name == "note.txt" }).url]

        XCTAssertNil(model.favoriteTarget, "파일이 즐겨찾기 대상이 됐다")
        XCTAssertFalse(model.isFavoriteTargetRegistered)
    }

    func testFavoriteTarget_multipleSelection_isNil() async throws {
        _ = try Fixture.makeDirectory(in: testRoot, name: "Alpha")
        _ = try Fixture.makeDirectory(in: testRoot, name: "Bravo")
        let model = makeModel()
        model.start()
        await waitUntil { model.directory.items.count >= 2 }

        model.directory.selection = Set(model.directory.items.map(\.url))

        XCTAssertNil(model.favoriteTarget, "다중 선택에서 즐겨찾기 대상이 하나로 정해졌다")
    }

    /// 메뉴 문구는 상태에 따라 **한 항목이 토글**된다 — 그 판정값이 등록 상태를 따라가는지.
    func testIsFavoriteTargetRegistered_followsRegistrationState() {
        let model = makeModel()
        let target = try? XCTUnwrap(model.favoriteTarget)

        XCTAssertFalse(model.isFavoriteTargetRegistered)
        model.toggleFavoriteForCurrentTarget()
        XCTAssertTrue(model.isFavoriteTargetRegistered)
        XCTAssertEqual(model.settings.favoritePaths.count, 1)

        model.toggleFavoriteForCurrentTarget()
        XCTAssertFalse(model.isFavoriteTargetRegistered)
        XCTAssertTrue(model.settings.favoritePaths.isEmpty)
        XCTAssertNotNil(target)
    }
}
