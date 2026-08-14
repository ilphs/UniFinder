import XCTest
@testable import UniFinder

/// `DirectoryWatcher` 단위 테스트 (m3-impl T0 — B5·B6·B7·B8).
///
/// 실제 `FSEventStream`/`DispatchSource` 파일시스템 이벤트를 단위 테스트에서 결정적으로
/// 재현하기는 어렵다. `DirectoryWatcher`는 이를 의식해 **"debounce 창 진입점"을 파일시스템 없이
/// 직접 호출할 수 있도록 `noteChange()`/`noteVanished()`를 공개**해뒀다(코드 주석 — "이 진입점을
/// 파일시스템 없이 직접 호출해 단위 테스트한다"). 이 파일은 그 계약을 그대로 사용한다.
@MainActor
final class DirectoryWatcherTests: TempDirectoryTestCase {

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - debounce 병합: 연속 이벤트는 1회 갱신으로 합쳐진다

    func testNoteChange_rapidSuccessiveCalls_mergeIntoSingleOnChange() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "watched")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        var changeCount = 0
        var lastURL: URL?
        watcher.onChange = { url in
            changeCount += 1
            lastURL = url
        }
        watcher.watch(folder)

        // 대량 변경이 연속으로 들어오는 상황을 흉내낸다(FSEvents 콜백 다회 호출).
        for _ in 0..<20 {
            watcher.noteChange()
        }

        await waitUntil(timeout: 1.0) { changeCount > 0 }
        // 병합 창이 끝난 뒤 추가로 잠깐 더 기다려 중복 호출이 없는지 확인한다.
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(changeCount, 1, "debounce 창 안의 연속 호출은 갱신 1회로 병합되어야 함")
        XCTAssertEqual(lastURL?.path, PathKey.directoryURL(folder).path)
    }

    /// debounce 창이 완전히 끝난 뒤 새 변경이 오면 별개의 갱신으로 다시 카운트되어야 한다.
    func testNoteChange_afterDebounceWindowElapses_firesAgainForNextBatch() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "watched")
        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        var changeCount = 0
        watcher.onChange = { _ in changeCount += 1 }
        watcher.watch(folder)

        watcher.noteChange()
        await waitUntil(timeout: 1.0) { changeCount == 1 }

        watcher.noteChange()
        await waitUntil(timeout: 1.0) { changeCount == 2 }

        XCTAssertEqual(changeCount, 2, "이전 병합 창이 끝난 뒤의 변경은 새 갱신으로 취급되어야 함")
    }

    // MARK: - 감시 대상 교체 시 낡은 갱신을 흘리지 않음

    func testNoteChange_pendingDebounce_isDiscardedWhenWatchedURLChangesBeforeItFires() async throws {
        let folderA = try Fixture.makeDirectory(in: testRoot, name: "a")
        let folderB = try Fixture.makeDirectory(in: testRoot, name: "b")
        let watcher = DirectoryWatcher(debounce: .milliseconds(80))
        var receivedURLs: [URL] = []
        watcher.onChange = { receivedURLs.append($0) }

        watcher.watch(folderA)
        watcher.noteChange()
        // 병합 창이 끝나기 전에 감시 대상을 B로 교체한다(예: 사용자가 재빨리 다른 폴더로 이동).
        watcher.watch(folderB)

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(receivedURLs.isEmpty, "낡은 감시 대상(A)에 대한 대기 중 갱신이 새 대상 전환 후에도 발화하면 안 됨")
    }

    // MARK: - 감시 대상 폴더 자신의 소실

    func testNoteVanished_firesOnVanishedCallback_andStopsWatching() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "willVanish")
        let watcher = DirectoryWatcher()
        var vanishedURL: URL?
        watcher.onVanished = { vanishedURL = $0 }
        watcher.watch(folder)

        watcher.noteVanished()

        XCTAssertEqual(vanishedURL?.path, PathKey.directoryURL(folder).path)
        XCTAssertNil(watcher.watchedURL, "소실 통지 후에는 감시 상태가 정리되어야 함")
    }

    /// 소실 시점에 대기 중이던 debounce 갱신은 의미가 없으므로 버려져야 한다(중복/스테일 갱신 방지).
    func testNoteVanished_discardsAnyPendingDebouncedChange() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "willVanish")
        let watcher = DirectoryWatcher(debounce: .milliseconds(80))
        var changeCount = 0
        var vanishedCount = 0
        watcher.onChange = { _ in changeCount += 1 }
        watcher.onVanished = { _ in vanishedCount += 1 }
        watcher.watch(folder)

        watcher.noteChange()
        watcher.noteVanished()

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(vanishedCount, 1)
        XCTAssertEqual(changeCount, 0, "소실 처리 후 대기 중이던 갱신이 뒤늦게 발화하면 안 됨")
    }

    // MARK: - watch(_:) 재설치 규칙

    func testWatch_sameFolderAgain_doesNotResetOrDropPendingDebounce() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "same")
        let watcher = DirectoryWatcher(debounce: .milliseconds(80))
        var changeCount = 0
        watcher.onChange = { _ in changeCount += 1 }
        watcher.watch(folder)

        watcher.noteChange()
        // 같은 폴더에 대한 재설치 요청 — 재설치로 이벤트를 흘리면 안 된다(코드 주석의 의도).
        watcher.watch(folder)

        await waitUntil(timeout: 1.0) { changeCount == 1 }
        XCTAssertEqual(changeCount, 1, "같은 폴더 재설치가 대기 중이던 갱신을 지우면 안 됨")
    }

    func testWatch_differentFolder_updatesWatchedURL() throws {
        let folderA = try Fixture.makeDirectory(in: testRoot, name: "a")
        let folderB = try Fixture.makeDirectory(in: testRoot, name: "b")
        let watcher = DirectoryWatcher()

        watcher.watch(folderA)
        XCTAssertEqual(watcher.watchedURL?.path, PathKey.directoryURL(folderA).path)

        watcher.watch(folderB)
        XCTAssertEqual(watcher.watchedURL?.path, PathKey.directoryURL(folderB).path)
    }

    // MARK: - stop()

    func testStop_clearsWatchedURL_andSuppressesPendingDebounce() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "toStop")
        let watcher = DirectoryWatcher(debounce: .milliseconds(80))
        var changeCount = 0
        watcher.onChange = { _ in changeCount += 1 }
        watcher.watch(folder)
        watcher.noteChange()

        watcher.stop()

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(watcher.watchedURL)
        XCTAssertEqual(changeCount, 0, "stop() 이후 대기 중이던 갱신이 발화하면 안 됨")
    }

    /// 존재하지 않는/접근 불가 경로는 감시를 조용히 포기해야 한다(수동 새로고침은 그대로 동작).
    func testWatch_nonExistentPath_failsGracefullyWithoutCrashing() {
        let watcher = DirectoryWatcher()
        let ghost = testRoot.appendingPathComponent("does-not-exist", isDirectory: true)

        watcher.watch(ghost)

        XCTAssertNil(watcher.watchedURL, "존재하지 않는 경로는 감시 대상으로 등록되면 안 됨")
    }
}
