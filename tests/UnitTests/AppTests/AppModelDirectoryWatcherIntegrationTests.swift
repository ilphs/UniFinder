import XCTest
@testable import UniFinder

/// M3 T0 — `AppModel`이 `DirectoryWatcher`를 실제로 어떻게 소비하는지 (m3-impl B7·B8·B23).
///
/// `DirectoryWatcherTests`는 `DirectoryWatcher` 자체(debounce/소실 판정)를, `DirectoryModel*UpdateTests`는
/// in-place 갱신 API를 각각 단위로 검증한다. 이 파일은 그 둘을 이어붙이는 `AppModel.handleExternalChange`/
/// `handleWatchedDirectoryVanished`의 배선을 검증한다 — `AppModel(directoryWatcher:)` 주입 지점을 쓴다.
///
/// `AppModel.navigate`/`handleWatchedDirectoryVanished`는 **실제 파일시스템**으로 존재 여부를
/// 확인하므로(`nearestExistingDirectory`), 이 테스트는 `TempDirectoryTestCase`의 실제 임시 폴더를
/// 쓴다(목록 **내용**은 `MockDirectoryListing`으로 결정적으로 제어한다).
@MainActor
final class AppModelDirectoryWatcherIntegrationTests: TempDirectoryTestCase {

    private func item(in directory: URL, name: String) -> FileItem {
        FileItem(
            url: directory.appendingPathComponent(name),
            name: name,
            isDirectory: false,
            isHidden: false,
            isSymlink: false,
            size: 0,
            modifiedAt: Fixture.fixedDate(),
            typeDescription: "Text"
        )
    }

    private func makeAppModel(loader: any DirectoryListing, startURL: URL) -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelWatcherTests-\(UUID().uuidString)")!),
            loader: loader,
            directoryWatcher: DirectoryWatcher(),
            startURL: startURL
        )
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// **실제 디스크에 만들지 않은** 경로. `DirectoryWatcher.watch(_:)`는 `open(O_EVTONLY)`가
    /// 실패하면 조용히 감시를 포기하므로(권한 없음/부재 시 정상 동작), 이 경로에 대해서는
    /// 실제 `DispatchSource`(커널 kqueue)가 전혀 설치되지 않는다 — 이 파일의 콜백 배선 테스트는
    /// FSEvents 콜백을 **직접 호출**해 시뮬레이션하므로 실제 fd/커널 이벤트가 필요 없고, 오히려
    /// 실 디렉터리를 감시하면 같은 프로세스에서 동시에 도는 다른 테스트 스위트의 디스크 I/O가
    /// 우연히 실제 커널 이벤트를 유발해 결과가 흔들릴 수 있다(실측 — 전체 스위트 동시 실행 시에만
    /// 간헐적으로 선택 필터링이 어긋나는 현상 재현, 이 파일 단독 실행 시에는 항상 통과).
    private func fakePath(_ name: String) -> URL {
        testRoot.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - onChange → in-place 갱신(스크롤/선택 유지)

    func testExternalChange_forCurrentFolder_refreshesInPlace_keepingSurvivingSelection() async throws {
        let watched = fakePath("watched")
        let mock = MockDirectoryListing()
        let a = item(in: watched, name: "a.txt")
        let b = item(in: watched, name: "b.txt")
        await mock.configure(url: watched, items: [a, b])
        let appModel = makeAppModel(loader: mock, startURL: watched)
        appModel.start()
        await waitUntil { !appModel.directory.items.isEmpty }
        appModel.directory.selection = [a.url, b.url]

        // 외부에서 b가 삭제되고 c가 생겼다고 가정 — FSEvents 콜백을 직접 시뮬레이션한다.
        let c = item(in: watched, name: "c.txt")
        await mock.configure(url: watched, items: [a, c])
        appModel.directoryWatcher.onChange?(watched)

        await waitUntil {
            appModel.directory.items.count == 2 && Set(appModel.directory.items.map(\.name)) == ["a.txt", "c.txt"]
        }

        XCTAssertEqual(appModel.directory.selection, [a.url], "생존한 항목(a)의 선택은 유지, 삭제된 b만 해제되어야 함(B5)")
        appModel.stop()
    }

    /// 표시 중이지 않은(과거) 폴더에 대한 뒤늦은 통지는 무시해야 한다.
    func testExternalChange_forStaleFolder_afterNavigatingAway_isIgnored() async throws {
        let watched = try Fixture.makeDirectory(in: testRoot, name: "watched")
        let other = try Fixture.makeDirectory(in: testRoot, name: "other")
        let mock = MockDirectoryListing()
        await mock.configure(url: watched, items: [item(in: watched, name: "a.txt")])
        await mock.configure(url: other, items: [])
        let appModel = makeAppModel(loader: mock, startURL: watched)
        appModel.start()
        await waitUntil { !appModel.directory.items.isEmpty }

        appModel.navigate(to: other, source: .toolbar)
        await waitUntil { appModel.directory.currentURL?.path == other.path }

        let revisionBefore = appModel.directory.contentsRevision
        // 예전 폴더(watched)에 대한 통지가 뒤늦게 도착한 상황.
        appModel.directoryWatcher.onChange?(watched)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appModel.directory.contentsRevision, revisionBefore, "표시 중이 아닌 폴더의 통지는 무시되어야 함")
        appModel.stop()
    }

    // MARK: - onVanished → 상위로 자동 이동 (모달 없음)

    func testWatchedDirectoryVanished_forCurrentFolder_movesToNearestExistingParent() async throws {
        let watched = try Fixture.makeDirectory(in: testRoot, name: "watched")
        let mock = MockDirectoryListing()
        await mock.configure(url: watched, items: [item(in: watched, name: "a.txt")])
        await mock.configure(url: testRoot, items: [])
        let appModel = makeAppModel(loader: mock, startURL: watched)
        appModel.start()
        await waitUntil { appModel.directory.currentURL?.path == watched.path }

        // 실제로 사라진 상황을 재현해야 `nearestExistingDirectory`가 상위로 판정한다.
        try FileManager.default.removeItem(at: watched)
        appModel.directoryWatcher.onVanished?(watched)

        await waitUntil { appModel.navigation.currentURL.path != watched.path }

        XCTAssertNotEqual(appModel.navigation.currentURL.path, watched.path, "감시 폴더 소실 시 상위로 이동해야 함")
        XCTAssertNotNil(appModel.transientMessage, "상위 이동은 모달이 아니라 상태바 안내로 알려야 함(설계 §8)")
        appModel.stop()
    }

    /// 표시 중이지 않은 폴더의 소실 통지는 무시해야 한다(경쟁 상황 방지).
    func testWatchedDirectoryVanished_forStaleFolder_isIgnored() async throws {
        let watched = try Fixture.makeDirectory(in: testRoot, name: "watched")
        let other = try Fixture.makeDirectory(in: testRoot, name: "other")
        let mock = MockDirectoryListing()
        await mock.configure(url: watched, items: [item(in: watched, name: "a.txt")])
        await mock.configure(url: other, items: [item(in: other, name: "x.txt")])
        let appModel = makeAppModel(loader: mock, startURL: watched)
        appModel.start()
        await waitUntil { !appModel.directory.items.isEmpty }

        appModel.navigate(to: other, source: .toolbar)
        await waitUntil { appModel.directory.currentURL?.path == other.path }

        try FileManager.default.removeItem(at: watched)
        appModel.directoryWatcher.onVanished?(watched)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appModel.navigation.currentURL.path, other.path, "표시 중이 아닌 폴더의 소실 통지가 현재 위치를 바꾸면 안 됨")
        appModel.stop()
    }

    // MARK: - B23: 인라인 편집 중 외부 변경은 보류됐다가, 편집 종료 시 1회 반영

    func testExternalChange_whileRenaming_isSuppressed_thenFlushedWhenRenamingEnds() async throws {
        let watched = fakePath("watched")
        let mock = MockDirectoryListing()
        let a = item(in: watched, name: "a.txt")
        await mock.configure(url: watched, items: [a])
        let appModel = makeAppModel(loader: mock, startURL: watched)
        appModel.start()
        await waitUntil { !appModel.directory.items.isEmpty }

        appModel.isRenaming = true
        let b = item(in: watched, name: "b.txt")
        await mock.configure(url: watched, items: [a, b])
        let revisionBeforeChange = appModel.directory.contentsRevision
        appModel.directoryWatcher.onChange?(watched)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            appModel.directory.contentsRevision, revisionBeforeChange,
            "인라인 편집 중에는 외부 변경이 화면에 반영되면 안 된다(편집 중인 셀이 사라짐 — architect B7과 같은 규칙)"
        )

        appModel.isRenaming = false
        await waitUntil(timeout: 5.0) { appModel.directory.items.count == 2 }

        XCTAssertEqual(Set(appModel.directory.items.map(\.name)), ["a.txt", "b.txt"], "편집 종료 시 보류된 변경이 1회 반영되어야 함(B23)")
        appModel.stop()
    }
}
