import XCTest
@testable import UniFinder

/// 즐겨찾기 저장소 (`AppSettings`) 단위 테스트 — 2026-08-18 사용자 요청 B단계.
///
/// **격리**: 모든 테스트가 `UserDefaults(suiteName:)`로 만든 전용 도메인을 쓴다.
/// `.standard`를 쓰면 개발 머신의 실제 즐겨찾기를 덮어쓴다(테스트계획서 §1 원칙 1과 같은 취지).
@MainActor
final class AppSettingsFavoritesTests: TempDirectoryTestCase {

    /// 테스트마다 새 suite를 만들고 teardown에서 지운다.
    ///
    /// `setUpWithError`/`tearDownWithError`는 nonisolated 오버라이드라 `@MainActor` 저장 프로퍼티를
    /// 건드릴 수 없다(Swift 5 targeted 동시성 진단). 그래서 상태를 들고 있지 않고
    /// **각 테스트가 필요할 때 만들어 쓰는** 방식으로 둔다.
    private func makeDefaults() -> UserDefaults {
        let name = "com.unifinder.tests.favorites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }


    // MARK: - 최초 실행 시딩

    /// 키가 아예 없으면 기존 하드코딩과 같은 3개(데스크탑/다운로드/문서)를 넣는다.
    func testInit_withoutStoredKey_seedsDefaultThreeFavorites() {
        let settings = AppSettings(defaults: makeDefaults())

        let expected: [FileManager.SearchPathDirectory] = [.desktopDirectory, .downloadsDirectory, .documentDirectory]
        let expectedPaths = expected.compactMap {
            FileManager.default.urls(for: $0, in: .userDomainMask).first.map(PathKey.exactPath)
        }

        XCTAssertEqual(settings.favoritePaths, expectedPaths, "최초 실행 시딩이 기존 고정 3개와 달라졌다")
        XCTAssertFalse(settings.favoritePaths.isEmpty)
    }

    /// **핵심 회귀**: 사용자가 전부 지운 상태(빈 배열)를 다음 실행에서 3개로 되살리면 안 된다.
    /// "키 부재"와 "빈 배열"을 구분하지 않으면 즐겨찾기를 영영 비울 수 없다.
    func testInit_withStoredEmptyArray_doesNotReseed() {
        let defaults = makeDefaults()
        let first = AppSettings(defaults: defaults)
        for url in first.favoriteURLs {
            first.removeFavorite(url)
        }
        XCTAssertTrue(first.favoritePaths.isEmpty)

        let second = AppSettings(defaults: defaults)

        XCTAssertTrue(second.favoritePaths.isEmpty, "빈 배열이 키 부재로 오판돼 기본값이 되살아났다")
    }

    func testInit_withStoredValues_restoresOrder() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let b = try Fixture.makeDirectory(in: testRoot, name: "B")

        let defaults = makeDefaults()
        let first = AppSettings(defaults: defaults)
        for url in first.favoriteURLs { first.removeFavorite(url) }
        first.addFavorite(a)
        first.addFavorite(b)

        let second = AppSettings(defaults: defaults)

        XCTAssertEqual(second.favoritePaths, [PathKey.exactPath(a), PathKey.exactPath(b)], "저장 순서가 보존되지 않음")
    }

    /// 저장된 값에 중복이 섞여 있어도(수동 편집·이전 버전 잔재) 한 번만 남아야 한다.
    func testInit_withDuplicateStoredValues_deduplicates() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let defaults = makeDefaults()
        defaults.set([PathKey.exactPath(a), a.path + "/", PathKey.exactPath(a).uppercased()], forKey: "favoritePaths")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.favoritePaths.count, 1, "표기만 다른 중복 항목이 그대로 남았다: \(settings.favoritePaths)")
    }

    // MARK: - 중복 등록 거부

    func testAddFavorite_duplicate_isRejected() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let settings = AppSettings(defaults: makeDefaults())
        for url in settings.favoriteURLs { settings.removeFavorite(url) }

        XCTAssertTrue(settings.addFavorite(a))
        XCTAssertFalse(settings.addFavorite(a), "같은 경로가 두 번 등록됐다")
        XCTAssertEqual(settings.favoritePaths.count, 1)
    }

    /// 중복 판정은 문자열 단순 비교가 아니라 `PathKey` 정규화 기준이어야 한다
    /// (후행 슬래시·대소문자 차이는 같은 폴더다 — 이 프로젝트가 반복해서 물린 지점).
    func testAddFavorite_normalizedVariants_areTreatedAsDuplicates() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "Mixed")
        let settings = AppSettings(defaults: makeDefaults())
        for url in settings.favoriteURLs { settings.removeFavorite(url) }
        XCTAssertTrue(settings.addFavorite(a))

        let withSlash = URL(fileURLWithPath: a.path, isDirectory: true)
        let upperCased = URL(fileURLWithPath: a.path.replacingOccurrences(of: "Mixed", with: "MIXED"))

        XCTAssertFalse(settings.addFavorite(withSlash), "후행 슬래시 표기가 다른 항목으로 등록됐다")
        XCTAssertFalse(settings.addFavorite(upperCased), "대소문자만 다른 항목으로 등록됐다")
        XCTAssertEqual(settings.favoritePaths.count, 1)
    }

    func testIsFavorite_matchesRegardlessOfNotation() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let settings = AppSettings(defaults: makeDefaults())
        settings.addFavorite(a)

        XCTAssertTrue(settings.isFavorite(a))
        XCTAssertTrue(settings.isFavorite(URL(fileURLWithPath: a.path, isDirectory: true)))
        XCTAssertFalse(settings.isFavorite(testRoot))
    }

    // MARK: - 해제

    func testRemoveFavorite_removesEntryAndReportsResult() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let settings = AppSettings(defaults: makeDefaults())
        settings.addFavorite(a)

        XCTAssertTrue(settings.removeFavorite(URL(fileURLWithPath: a.path, isDirectory: true)))
        XCTAssertFalse(settings.isFavorite(a))
        XCTAssertFalse(settings.removeFavorite(a), "없는 항목 제거는 false여야 한다")
    }

    /// **즐겨찾기 해제는 파일시스템을 건드리지 않는다** — 삭제와 다른 개념이라는 규약의 회귀 테스트.
    func testRemoveFavorite_doesNotTouchFileSystem() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "A")
        let keep = try Fixture.makeFile(in: a, name: "keep.txt")
        let settings = AppSettings(defaults: makeDefaults())
        settings.addFavorite(a)

        settings.removeFavorite(a)

        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "즐겨찾기 해제가 폴더를 지웠다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    /// 사라진 경로도 저장소에는 남는다 — 외장 볼륨이 잠깐 빠진 상황에서 등록을 잃지 않기 위함.
    /// (표시에서 거르는 책임은 `TreeModel`에 있다)
    func testFavoritePaths_keepsGhostPathInStore() throws {
        let ghost = try Fixture.makeDirectory(in: testRoot, name: "ghost")
        let settings = AppSettings(defaults: makeDefaults())
        settings.addFavorite(ghost)

        try FileManager.default.removeItem(at: ghost)

        XCTAssertTrue(settings.isFavorite(ghost), "사라진 경로가 저장소에서 즉시 지워졌다(복구 불가 — 정책 위반)")
    }
}
