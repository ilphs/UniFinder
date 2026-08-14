import XCTest
@testable import UniFinder

/// M3 T0 — `AppModel`이 외부 변경 통지를 처리하는 방식 (m3-impl B6·B7·B23). ralph 작성.
///
/// `DirectoryWatcher`/`DirectoryModel` 각각의 단위 테스트가 있지만, **둘을 잇는 규칙**은 여기서만
/// 검증된다:
/// - 감시 대상은 표시 중 폴더를 따라간다(이동하면 옮겨 붙는다)
/// - 편집/모달 중 도착한 변경은 **보류**했다가 풀린 뒤 1회 반영한다(B23 — 모달 뒤에서 목록이
///   갈아엎히지 않아야 한다)
/// - 폴더 자체가 사라지면 상위로 이동하고 상태바로 안내한다(모달 없이 — 설계서 §6)
@MainActor
final class AppModelExternalChangeTests: TempDirectoryTestCase {

    private func makeAppModel(startURL: URL, watcher: DirectoryWatcher) -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelExternalChange-\(UUID().uuidString)")!),
            directoryWatcher: watcher,
            startURL: startURL
        )
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 감시 대상 추적

    func testNavigate_movesWatcherToTheNewlyDisplayedFolder() async throws {
        let first = try Fixture.makeDirectory(in: testRoot, name: "first")
        let second = try Fixture.makeDirectory(in: testRoot, name: "second")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: first, watcher: watcher)

        model.navigate(to: second, source: .toolbar)
        await waitUntil { watcher.watchedURL != nil }

        XCTAssertEqual(
            watcher.watchedURL.map(PathKey.key), PathKey.key(second),
            "이동 후에도 이전 폴더를 감시하면 엉뚱한 폴더의 변경으로 화면이 갱신된다"
        )
    }

    // MARK: - 외부 변경 반영

    func testExternalChange_updatesListInPlace_withoutBumpingRevision() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        try Fixture.makeFile(in: folder, name: "a.txt")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)

        model.navigate(to: folder, source: .toolbar)
        await waitUntil { model.directory.items.count == 1 }
        let revisionBefore = model.directory.revision

        try Fixture.makeFile(in: folder, name: "b.txt")
        watcher.noteChange()
        await waitUntil { model.directory.items.count == 2 }

        XCTAssertEqual(model.directory.items.map(\.name).sorted(), ["a.txt", "b.txt"])
        XCTAssertEqual(
            model.directory.revision, revisionBefore,
            "외부 갱신이 revision을 올리면 브릿지가 스크롤을 최상단으로 되돌린다(B5)"
        )
    }

    /// B23 — 인라인 편집 중에는 갱신을 보류하고, 편집이 끝난 뒤 1회 반영한다.
    /// (편집 중 재열거하면 편집 중인 셀이 통째로 사라진다)
    func testExternalChange_whileRenaming_isDeferredUntilEditingEnds() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        try Fixture.makeFile(in: folder, name: "a.txt")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)

        model.navigate(to: folder, source: .toolbar)
        await waitUntil { model.directory.items.count == 1 }

        model.isRenaming = true
        try Fixture.makeFile(in: folder, name: "b.txt")
        watcher.noteChange()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(model.directory.items.count, 1, "편집 중 목록이 갈아엎히면 편집 중인 셀이 사라진다")

        model.isRenaming = false
        await waitUntil { model.directory.items.count == 2 }
        XCTAssertEqual(model.directory.items.count, 2, "편집이 끝나면 보류된 변경이 반영되어야 한다")
    }

    // MARK: - 폴더 소실 (설계서 §6)

    func testWatchedFolderVanished_movesToNearestExistingParent_withStatusBarMessage() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)

        model.navigate(to: folder, source: .toolbar)
        await waitUntil { PathKey.isSame(model.navigation.currentURL, folder) }

        try FileManager.default.removeItem(at: folder)
        watcher.noteVanished()
        await waitUntil { !PathKey.isSame(model.navigation.currentURL, folder) }

        XCTAssertEqual(
            PathKey.key(model.navigation.currentURL), PathKey.key(testRoot),
            "사라진 폴더에 갇히지 않고 가장 가까운 상위로 이동해야 한다(설계서 §6)"
        )
        XCTAssertEqual(model.transientMessage, "폴더가 사라져 상위 폴더로 이동했습니다.", "안내는 모달이 아니라 상태바 문구여야 한다")
    }

    /// **M3 리뷰 권장 2 회귀** — 같은 경로에 폴더가 다시 만들어지면 내용도 다시 읽어야 한다.
    ///
    /// 예전에는 이 분기가 `syncWatcher()`만 호출했다. 그래서 폴더가 통째로 교체된 상황에서
    /// 화면은 사라진 옛 폴더의 목록을 그대로 들고 스테일해졌다(사용자가 F5를 누르기 전까지).
    func testWatchedFolderRecreatedAtSamePath_refreshesContents() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        try Fixture.makeFile(in: folder, name: "old.txt")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)

        model.navigate(to: folder, source: .toolbar)
        await waitUntil { model.directory.items.count == 1 }

        // 폴더가 통째로 교체된다(삭제 → 같은 이름으로 재생성).
        try FileManager.default.removeItem(at: folder)
        let recreated = try Fixture.makeDirectory(in: testRoot, name: "folder")
        try Fixture.makeFile(in: recreated, name: "new.txt")
        watcher.noteVanished()
        await waitUntil { model.directory.items.map(\.name) == ["new.txt"] }

        XCTAssertEqual(
            model.directory.items.map(\.name), ["new.txt"],
            "같은 경로가 다시 만들어졌는데 목록을 갱신하지 않으면 사라진 폴더의 내용이 계속 보인다(권장 2)"
        )
        XCTAssertEqual(
            PathKey.key(model.navigation.currentURL), PathKey.key(folder),
            "경로가 살아 있으므로 상위로 내려가면 안 된다"
        )
    }

    /// 재생성 갱신도 편집/모달 중에는 다른 외부 변경과 같은 규칙으로 보류된다(B7·B23).
    func testWatchedFolderRecreated_whileRenaming_isDeferredUntilEditingEnds() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        try Fixture.makeFile(in: folder, name: "old.txt")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)

        model.navigate(to: folder, source: .toolbar)
        await waitUntil { model.directory.items.count == 1 }

        model.isRenaming = true
        try FileManager.default.removeItem(at: folder)
        let recreated = try Fixture.makeDirectory(in: testRoot, name: "folder")
        try Fixture.makeFile(in: recreated, name: "new.txt")
        watcher.noteVanished()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(model.directory.items.map(\.name), ["old.txt"], "편집 중 목록이 갈아엎히면 편집 셀이 사라진다")

        model.isRenaming = false
        await waitUntil { model.directory.items.map(\.name) == ["new.txt"] }
        XCTAssertEqual(
            model.directory.items.map(\.name), ["new.txt"],
            "보류된 갱신이 `syncWatcher`의 무조건 리셋에 삼켜지면 화면이 영영 스테일해진다"
        )
    }

    // MARK: - B7: FSEvents가 조작 결과 반영을 대체하지 않는다

    /// 붙여넣기 등 자기 조작의 결과 반영은 `applyOperationResult`가 계속 담당한다.
    /// 감시가 걸려 있지 않은 상태(감시 실패·다른 폴더)에서도 조작 결과는 화면에 반영되어야 한다.
    func testOperationResult_isAppliedEvenWithoutAnyWatcherEvent() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        let model = makeAppModel(startURL: testRoot, watcher: watcher)
        model.navigate(to: folder, source: .toolbar)
        await waitUntil { model.directory.currentURL != nil }

        model.createFolder(in: folder)
        await waitUntil { model.directory.items.contains { $0.name == "새 폴더" } }

        XCTAssertTrue(
            model.directory.items.contains { $0.name == "새 폴더" },
            "조작 결과 반영을 FSEvents에 맡기면 감시가 없는 경로에서 화면이 갱신되지 않는다(B7)"
        )
    }
}
