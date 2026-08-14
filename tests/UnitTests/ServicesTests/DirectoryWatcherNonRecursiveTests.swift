import XCTest
@testable import UniFinder

/// M3 T0/B8 — **감시가 실제로 비재귀인지**를 실 파일시스템 이벤트로 증명한다 (ralph 작성).
///
/// `DirectoryWatcherTests`(test-engineer)는 `noteChange()`/`noteVanished()` 진입점의 병합·정리
/// 규칙을 다룬다. 이 파일은 그 위층 — `watch(_:)`가 커널에서 받아오는 이벤트의 **범위**를 고정한다.
///
/// B8이 요구한 것은 "직속 자식 변경만 갱신을 유발한다"이고, 그 근거가 "1만 파일 생성 중 UI 프리즈
/// 없음" 수용 기준이다. FSEventStream(재귀)을 썼다면 하위 트리의 대량 변경이 전부 유입되어
/// 이 테스트가 실패한다.
final class DirectoryWatcherNonRecursiveTests: TempDirectoryTestCase {

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 직속 자식 생성은 감지되어야 한다(감시가 살아 있다는 정방향 증거 — 아래 음성 테스트의 전제).
    @MainActor
    func testWatch_directChildCreated_deliversChange() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "watched")
        let watcher = DirectoryWatcher(debounce: .milliseconds(100))
        var changeCount = 0
        watcher.onChange = { _ in changeCount += 1 }
        watcher.watch(folder)

        try Fixture.makeFile(in: folder, name: "new.txt")
        await waitUntil { changeCount >= 1 }

        XCTAssertGreaterThanOrEqual(changeCount, 1, "직속 자식 생성이 감지되지 않으면 자동 갱신 자체가 동작하지 않는다")
        watcher.stop()
    }

    @MainActor
    func testWatch_directChildDeleted_deliversChange() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "watched")
        let victim = try Fixture.makeFile(in: folder, name: "victim.txt")
        let watcher = DirectoryWatcher(debounce: .milliseconds(100))
        var changeCount = 0
        watcher.onChange = { _ in changeCount += 1 }
        watcher.watch(folder)

        try FileManager.default.removeItem(at: victim)
        await waitUntil { changeCount >= 1 }

        XCTAssertGreaterThanOrEqual(changeCount, 1, "직속 자식 삭제가 감지되지 않았다")
        watcher.stop()
    }

    /// **B8 핵심**: 이미 존재하는 하위 폴더 안에서 파일 200개를 만들어도 표시 중 폴더의 감시자는
    /// 깨어나지 않아야 한다. 재귀 감시라면 여기서 수백 건이 유입된다.
    @MainActor
    func testWatch_bulkChangesInsideSubtree_doNotReachWatchedDirectory() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "watched")
        let sub = try Fixture.makeDirectory(in: folder, name: "sub")
        let deeper = try Fixture.makeDirectory(in: sub, name: "deeper")

        let watcher = DirectoryWatcher(debounce: .milliseconds(100))
        var changeCount = 0
        watcher.onChange = { _ in changeCount += 1 }
        watcher.watch(folder)

        for index in 0..<200 {
            try Fixture.makeFile(in: deeper, name: "f\(index).txt")
        }
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(
            changeCount, 0,
            "하위 트리의 대량 변경이 표시 중 폴더까지 흔들면 갱신 폭주가 난다(B8 — 비재귀 감시 위반)"
        )
        watcher.stop()
    }

    /// 감시 대상 폴더 자신이 삭제되면 목록 갱신이 아니라 **소실 통지**여야 한다(설계서 §6 상위 이동).
    @MainActor
    func testWatch_watchedDirectoryRemoved_deliversVanishedFromRealFileSystemEvent() async throws {
        let target = try Fixture.makeDirectory(in: testRoot, name: "target")
        let watcher = DirectoryWatcher(debounce: .milliseconds(80))
        var vanished: [URL] = []
        watcher.onVanished = { vanished.append($0) }
        watcher.watch(target)

        try FileManager.default.removeItem(at: target)
        await waitUntil { !vanished.isEmpty }

        XCTAssertEqual(vanished.count, 1, "감시 대상 삭제가 소실 통지로 전달되지 않았다")
        XCTAssertNil(watcher.watchedURL)
        watcher.stop()
    }
}
