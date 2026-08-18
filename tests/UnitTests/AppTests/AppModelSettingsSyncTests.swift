import XCTest
@testable import UniFinder

/// 다중 창 지원 — 창 사이에 공유되는 `AppSettings`가 바뀌었을 때, **다른 창의 `AppModel`이
/// 자기 화면에도 그 변경을 반영**해야 한다는 회귀 테스트.
///
/// `AppSettings`는 창 사이에 공유되는 단일 인스턴스지만, 그걸 실제로 화면에 반영하는
/// `DirectoryModel.showHidden`/`TreeModel.showHidden`/`TreeModel.rebuildSections()`은
/// 창(=`AppModel`)마다 따로 갖는 로컬 상태다. 창 A에서 숨김 파일 표시를 켜거나 즐겨찾기를
/// 추가해도, 창 B가 그 변경을 스스로 당겨오는 동기화 API(`syncShowHiddenFromSettings`,
/// `syncFavoritesFromSettings`)를 호출하지 않으면 창 B의 화면은 낡은 상태로 남는다.
@MainActor
final class AppModelSettingsSyncTests: TempDirectoryTestCase {

    private func makeSharedSettings() -> AppSettings {
        let name = "UniFinderTests-SettingsSync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return AppSettings(defaults: defaults)
    }

    private func makeModel(settings: AppSettings, startURL: URL) -> AppModel {
        AppModel(settings: settings, startURL: startURL)
    }

    // MARK: - 숨김 항목 표시 동기화

    func testSyncShowHiddenFromSettings_reflectsOtherWindowsToggle() {
        let settings = makeSharedSettings()
        let modelA = makeModel(settings: settings, startURL: testRoot)
        let modelB = makeModel(settings: settings, startURL: testRoot)
        modelA.start()
        modelB.start()
        XCTAssertEqual(modelB.directory.showHidden, settings.showHidden, "전제 확인")

        modelA.toggleHiddenItems()
        XCTAssertNotEqual(modelA.directory.showHidden, modelB.directory.showHidden, "동기화 전에는 아직 창 B에 반영되지 않는다(전제)")

        modelB.syncShowHiddenFromSettings()

        XCTAssertEqual(modelB.directory.showHidden, settings.showHidden, "창 B의 목록이 공유 설정과 동기화되어야 한다")
        XCTAssertEqual(modelB.tree.showHidden, settings.showHidden, "창 B의 트리도 함께 동기화되어야 한다")
        modelA.stop()
        modelB.stop()
    }

    /// 값이 실제로 바뀌지 않았으면 굳이 재열거/재빌드를 하지 않아도 안전해야 한다(크래시·예외 없음).
    func testSyncShowHiddenFromSettings_noOpWhenAlreadyInSync() {
        let settings = makeSharedSettings()
        let modelA = makeModel(settings: settings, startURL: testRoot)
        modelA.start()

        modelA.syncShowHiddenFromSettings()

        XCTAssertEqual(modelA.directory.showHidden, settings.showHidden)
        modelA.stop()
    }

    // MARK: - 정렬 동기화

    func testSyncSortFromSettings_reflectsOtherWindowsSortChange() {
        let settings = makeSharedSettings()
        let modelA = makeModel(settings: settings, startURL: testRoot)
        let modelB = makeModel(settings: settings, startURL: testRoot)
        modelA.start()
        modelB.start()

        modelA.toggleSort(for: .size)
        XCTAssertEqual(settings.sortDescriptor.key, .size, "전제 확인")

        modelB.syncSortFromSettings()

        XCTAssertEqual(modelB.directory.sortDescriptor.key, .size, "창 B의 정렬 기준이 공유 설정과 동기화되어야 한다")
        modelA.stop()
        modelB.stop()
    }

    // MARK: - 즐겨찾기 동기화 — 소실 회귀 (AppSettings.swift 배열 전체 덮어쓰기 구조가 핵심)

    /// 창 A가 즐겨찾기를 추가한 뒤, 창 B가 `syncFavoritesFromSettings()`로 그걸 반영해야 한다.
    func testSyncFavoritesFromSettings_reflectsFavoriteAddedByOtherWindow() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Shared")
        let settings = makeSharedSettings()
        for url in settings.favoriteURLs { settings.removeFavorite(url) } // 시딩값 제거 — 결정적 상태로 시작
        let modelA = makeModel(settings: settings, startURL: testRoot)
        let modelB = makeModel(settings: settings, startURL: testRoot)
        modelA.start()
        modelB.start()

        modelA.addFavorite(folder)
        XCTAssertTrue(settings.isFavorite(folder), "전제 확인")

        modelB.syncFavoritesFromSettings()

        XCTAssertNotNil(modelB.tree.node(for: folder), "창 B의 트리에 창 A가 추가한 즐겨찾기가 나타나야 한다")
        modelA.stop()
        modelB.stop()
    }

    /// **핵심 회귀**: `AppSettings.addFavorite`는 `favoritePaths` 배열 전체를 재대입하는 구조라
    /// (`AppSettings.swift` — `favoritePaths.append(...)`가 `didSet`을 통해 배열 전체를 다시 쓴다),
    /// 창 B가 동기화 이후 자기 쪽에서 새 즐겨찾기를 추가할 때 창 A가 만든 항목을 **덮어써서 지우면**
    /// 안 된다. 최신 공유 상태(`AppSettings.favoritePaths`) 위에 추가해야 소실이 없다.
    func testSyncFavoritesFromSettings_windowBAddingAfterSync_doesNotEraseWindowAsFavorite() throws {
        let folderA = try Fixture.makeDirectory(in: testRoot, name: "FromA")
        let folderB = try Fixture.makeDirectory(in: testRoot, name: "FromB")
        let settings = makeSharedSettings()
        for url in settings.favoriteURLs { settings.removeFavorite(url) }
        let modelA = makeModel(settings: settings, startURL: testRoot)
        let modelB = makeModel(settings: settings, startURL: testRoot)
        modelA.start()
        modelB.start()

        modelA.addFavorite(folderA)
        modelB.syncFavoritesFromSettings()
        modelB.addFavorite(folderB)

        XCTAssertTrue(
            settings.isFavorite(folderA),
            "창 B가 이후 즐겨찾기를 추가하면서 창 A가 등록한 즐겨찾기를 지웠다 — 즐겨찾기 소실 회귀"
        )
        XCTAssertTrue(settings.isFavorite(folderB))
        modelA.stop()
        modelB.stop()
    }
}
