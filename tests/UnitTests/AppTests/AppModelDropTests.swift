import XCTest
@testable import UniFinder

/// M3 T3 드래그앤드롭 — **드롭 실행 진입점** 단위 테스트 (m3-impl B9·B10·B12·B13).
///
/// **가정하는 프로덕션 API** (m3-impl §2 T3 B9가 시그니처를 확정한 지점):
/// `AppModel.drop(_ urls: [URL], into destination: URL, operation: FileOperationKind)`
/// — 내부는 `paste(into:)`와 동일하게 `runOperation` → `applyOperationResult`를 경유해야 한다.
///
/// B10 — "UI 레벨 거부는 보조, 서비스 레벨 가드가 권위"이므로, 여기서는 **드롭 진입점을 거쳐도**
/// `FileOperationsSafetyTests`/`M2ProtectedTargetTests`가 고정한 가드가 그대로 지켜지는지를
/// **조작 후 파일 내용까지** 확인한다(에러 코드만 보지 않는다 — M2 리뷰 관례).
///
/// **테스트 안전성**: `FileOperations(homeDirectory:)`로 임시 폴더를 홈으로 주입한다
/// (실제 홈 대상 파괴적 테스트 금지 — M2 리뷰 지적사항).
@MainActor
final class AppModelDropTests: TempDirectoryTestCase {

    private func makeAppModel(homeDirectory: URL, startURL: URL) -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelDropTests-\(UUID().uuidString)")!),
            operations: FileOperations(homeDirectory: homeDirectory),
            startURL: startURL
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 조작은 `runOperation`의 Task 안에서 비동기로 끝난다. 결과를 관찰하려면 완료를 기다려야
    /// 하는데, 대상이 임시 폴더의 소용량 fixture라 완료는 사실상 즉시(수 ms) 일어난다.
    /// `operationTask`가 private이라 직접 폴링할 수 없으므로, 충분히 넉넉한 유예를 둔다.
    private func waitForOperationToSettle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - B10: 자기 자신/자기 하위 드롭 거부

    func testDrop_intoOwnSubdirectory_isRejectedAndOriginalKept() async throws {
        let fakeHome = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        let source = try Fixture.makeDirectory(in: testRoot, name: "source")
        let sub = try Fixture.makeDirectory(in: source, name: "sub")
        let payload = try Fixture.makeFile(in: sub, name: "payload.txt")
        let appModel = makeAppModel(homeDirectory: fakeHome, startURL: testRoot)

        appModel.drop([source], into: sub, operation: .copy)
        try await waitForOperationToSettle()

        XCTAssertFalse(exists(sub.appendingPathComponent("source")), "자기 하위로의 복사가 실행됐다(B10)")
        XCTAssertTrue(exists(payload), "원본 하위 항목이 그대로여야 함")
    }

    // MARK: - B10 / M2 백로그 B1: 별칭 경로 경유 하위 드롭 거부 (회귀)

    func testDrop_intoOwnDescendantReachedThroughAliasPath_isRejected() async throws {
        let fakeHome = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        let source = try Fixture.makeDirectory(in: testRoot, name: "source")
        let sub = try Fixture.makeDirectory(in: source, name: "sub")
        let payload = try Fixture.makeFile(in: sub, name: "payload.txt")
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: sub)
        let appModel = makeAppModel(homeDirectory: fakeHome, startURL: testRoot)

        appModel.drop([source], into: alias, operation: .move)
        try await waitForOperationToSettle()

        XCTAssertTrue(exists(source), "별칭 경로로 자기 하위 이동 가드가 드롭 진입점에서 뚫렸다(B1 회귀)")
        XCTAssertTrue(exists(payload))
        XCTAssertFalse(exists(sub.appendingPathComponent("source")), "무한 재귀 이동이 시작됐다")
    }

    // MARK: - B10: 보호 대상(홈 루트) 드래그 이동 거부

    func testDrop_movingProtectedHomeRoot_isRejectedAndKeptInPlace() async throws {
        let fakeHome = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        let keep = try Fixture.makeFile(in: fakeHome, name: "keep.txt")
        try "ORIGINAL".write(to: keep, atomically: true, encoding: .utf8)
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let appModel = makeAppModel(homeDirectory: fakeHome, startURL: testRoot)

        appModel.drop([fakeHome], into: destination, operation: .move)
        try await waitForOperationToSettle()

        XCTAssertTrue(exists(fakeHome), "홈 루트 드래그 이동이 드롭 진입점에서 거부되지 않았다(B10)")
        XCTAssertTrue(exists(keep))
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "ORIGINAL")
        XCTAssertFalse(exists(destination.appendingPathComponent("fake-home")), "보호 대상이 이동된 결과가 대상에 생기면 안 됨")
    }

    /// 보호 대상이라도 **복사**는 파괴적이지 않으므로 계속 허용되어야 한다(가드 과잉 확대 방지).
    func testDrop_copyingProtectedHomeRoot_isStillAllowed() async throws {
        let fakeHome = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        _ = try Fixture.makeFile(in: fakeHome, name: "keep.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let appModel = makeAppModel(homeDirectory: fakeHome, startURL: testRoot)

        appModel.drop([fakeHome], into: destination, operation: .copy)
        try await waitForOperationToSettle()

        XCTAssertTrue(exists(destination.appendingPathComponent("fake-home/keep.txt")), "보호 대상 복사(비파괴)까지 막으면 안 됨")
        XCTAssertTrue(exists(fakeHome.appendingPathComponent("keep.txt")))
    }

    // MARK: - B10 / M2 백로그 B2: 같은 폴더 드롭 = 무동작 (회귀)

    func testDrop_moveIntoSameFolder_isNoOpAndKeepsOriginal() async throws {
        let fakeHome = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        let file = try Fixture.makeFile(in: folder, name: "note.txt")
        try "ORIGINAL".write(to: file, atomically: true, encoding: .utf8)
        let appModel = makeAppModel(homeDirectory: fakeHome, startURL: testRoot)

        appModel.drop([file], into: folder, operation: .move)
        try await waitForOperationToSettle()

        XCTAssertTrue(exists(file), "원본이 사라졌다 — 데이터 손실")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ORIGINAL")
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(entries, ["note.txt"], "같은 폴더로의 이동 드롭은 no-op이어야 함(B2 회귀)")
    }

    func testDrop_copyIntoSameFolder_numbersCopyWithoutAsking() async throws {
        let fakeHome = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        let file = try Fixture.makeFile(in: folder, name: "note.txt")
        try "ORIGINAL".write(to: file, atomically: true, encoding: .utf8)
        let appModel = makeAppModel(homeDirectory: fakeHome, startURL: testRoot)

        appModel.drop([file], into: folder, operation: .copy)
        try await waitForOperationToSettle()

        XCTAssertTrue(exists(file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ORIGINAL")
        XCTAssertTrue(exists(folder.appendingPathComponent("note 2.txt")), "같은 폴더 복사 드롭은 자동 넘버링되어야 함(B2 회귀)")
    }

    // MARK: - B9: 드롭이 정상 목적지로 실제로 결과를 만듦(안전 경유점을 실제로 통과하는지 정방향 확인)

    func testDrop_moveToOrdinaryDestination_succeedsAndRemovesOriginal() async throws {
        let fakeHome = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        let file = try Fixture.makeFile(in: testRoot, name: "a.txt")
        try "HELLO".write(to: file, atomically: true, encoding: .utf8)
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let appModel = makeAppModel(homeDirectory: fakeHome, startURL: testRoot)

        appModel.drop([file], into: destination, operation: .move)
        try await waitForOperationToSettle()

        XCTAssertFalse(exists(file), "정상 이동 드롭이 원본을 남겨두면 안 됨")
        let moved = destination.appendingPathComponent("a.txt")
        XCTAssertTrue(exists(moved))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "HELLO")
    }

    // MARK: - B12: 조작 진행 중 드롭 거부

    /// `AppModel.runOperation`은 이미 진행 중이면 새 조작을 무시한다(기존 붙여넣기와 동일 가드).
    /// 드롭도 이 경유점을 타야 "드롭 성공 후 아무 일도 없음"이 아니라 애초에 무시되어야 한다.
    func testDrop_whileAnotherOperationIsInProgress_isIgnored() async throws {
        _ = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        let gated = GatedFileOperating()
        await gated.setGated(true)
        let a = URL(fileURLWithPath: "/tmp/AppModelDropTests-a.txt")
        let b = URL(fileURLWithPath: "/tmp/AppModelDropTests-b.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let appModel = AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "AppModelDropTests-\(UUID().uuidString)")!),
            operations: gated,
            startURL: testRoot
        )

        appModel.drop([a], into: destination, operation: .move)
        // 첫 조작이 게이트에 걸려 진행 중인 상태를 만든다.
        try await Task.sleep(nanoseconds: 100_000_000)
        let firstCallCount = await gated.moveCallCount
        XCTAssertEqual(firstCallCount, 1, "첫 드롭이 실행되지 않았다")

        appModel.drop([b], into: destination, operation: .move)
        try await Task.sleep(nanoseconds: 100_000_000)

        let secondCallCount = await gated.moveCallCount
        XCTAssertEqual(secondCallCount, 1, "진행 중에 들어온 두 번째 드롭이 실행되면 안 된다(B12)")
        XCTAssertEqual(
            appModel.transientMessage, "이전 파일 조작이 끝난 뒤에 다시 시도하세요.",
            "두 번째 드롭은 기존 붙여넣기와 같은 안내를 띄워야 한다"
        )

        await gated.release()
    }
}
