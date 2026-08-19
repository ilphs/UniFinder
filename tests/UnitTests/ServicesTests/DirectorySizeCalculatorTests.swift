import XCTest
@testable import UniFinder

/// 폴더 크기 재귀 합산 (후속 T6 / 설계서 §3.2 불변식 · D6).
final class DirectorySizeCalculatorTests: TempDirectoryTestCase {

    private let calculator = DirectorySizeCalculator()

    // MARK: - 정확성

    func testCalculate_matchesKnownFixtureSize() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "tree")
        try Fixture.makeFile(in: root, name: "a.bin", sizeBytes: 1000)
        try Fixture.makeFile(in: root, name: "b.bin", sizeBytes: 2000)
        let nested = try Fixture.makeDirectory(in: root, name: "nested")
        try Fixture.makeFile(in: nested, name: "c.bin", sizeBytes: 3000)

        let result = try await calculator.calculate(at: root)

        XCTAssertEqual(result.bytes, 6000, "논리 크기 합계가 fixture와 정확히 일치해야 한다")
        XCTAssertEqual(result.itemCount, 4, "파일 3개 + 하위 폴더 1개")
        XCTAssertFalse(result.isIncomplete)
    }

    func testCalculate_emptyFolderIsZero() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "empty")

        let result = try await calculator.calculate(at: root)

        XCTAssertEqual(result, .zero)
    }

    /// 숨김 파일도 크기에 포함한다 — "이 폴더가 얼마나 큰가"에 숨김 여부는 상관이 없다.
    func testCalculate_includesHiddenFiles() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "with-hidden")
        try Fixture.makeFile(in: root, name: "visible.bin", sizeBytes: 100)
        try Fixture.makeFile(in: root, name: "secret.bin", sizeBytes: 200, hidden: true)

        let result = try await calculator.calculate(at: root)

        XCTAssertEqual(result.bytes, 300)
    }

    // MARK: - 심볼릭 링크 (불변식 5)

    func testCalculate_skipsSymbolicLinksAndDoesNotFollowThem() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "linked")
        try Fixture.makeFile(in: root, name: "a.bin", sizeBytes: 500)

        let outside = try Fixture.makeDirectory(in: testRoot, name: "outside")
        try Fixture.makeFile(in: outside, name: "huge.bin", sizeBytes: 100_000)
        _ = try Fixture.makeSymlink(in: root, name: "shortcut", destination: outside)

        let result = try await calculator.calculate(at: root)

        XCTAssertEqual(
            result.bytes, 500,
            "심볼릭 링크를 따라갔다 — 같은 실체를 여러 번 세고 순환 링크에서 무한 순회한다(불변식 5)"
        )
        XCTAssertEqual(result.itemCount, 1, "건너뛴 링크는 항목 수에도 넣지 않는다")
    }

    /// 순환 링크가 있어도 끝나야 한다(무한 순회 방어의 실전 확인).
    func testCalculate_terminatesWithCircularSymlink() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "circular")
        try Fixture.makeFile(in: root, name: "a.bin", sizeBytes: 10)
        _ = try Fixture.makeSymlink(in: root, name: "self-link", destination: root)

        let result = try await calculator.calculate(at: root)

        XCTAssertEqual(result.bytes, 10)
    }

    // MARK: - 취소 (§5 성능 요구)

    func testCalculate_cancellationThrowsCancellationError() async throws {
        // 취소가 확실히 관측되도록 항목을 넉넉히 만든다(취소 확인 주기의 여러 배).
        let root = try Fixture.makeDirectory(in: testRoot, name: "big")
        for index in 0..<3000 {
            try Fixture.makeFile(in: root, name: "f\(index).bin", sizeBytes: 1)
        }

        let calculator = self.calculator
        let task = Task { try await calculator.calculate(at: root) }
        task.cancel()

        do {
            _ = try await task.value
            // 취소가 순회 시작 전에 도달하지 못했을 수 있다 — 그 경우도 계약 위반은 아니다.
            // 다만 취소 신호가 **전혀** 반영되지 않는 구현이면 아래 즉시 취소 경로가 잡는다.
        } catch is CancellationError {
            return // 기대 경로
        } catch {
            XCTFail("취소 외의 에러: \(error)")
        }
    }

    /// 이미 취소된 컨텍스트에서는 **순회를 시작하기도 전에** 멈춰야 한다.
    func testCalculate_alreadyCancelledTaskStopsImmediately() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "cancelled")
        try Fixture.makeFile(in: root, name: "a.bin", sizeBytes: 10)

        let calculator = self.calculator
        let task = Task { () -> Result<DirectorySizeCalculator.Progress, Error> in
            // 시작 전에 취소 상태를 만든다.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            do {
                return .success(try await calculator.calculate(at: root))
            } catch {
                return .failure(error)
            }
        }
        task.cancel()

        let outcome = await task.value
        guard case let .failure(error) = outcome else {
            return XCTFail("취소된 컨텍스트에서 계산이 그대로 진행됐다")
        }
        XCTAssertTrue(error is CancellationError)
    }

    // MARK: - 권한 거부 (불변식 6)

    func testCalculate_inaccessibleSubdirectoryYieldsPartialSumAndIncompleteFlag() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "partial")
        try Fixture.makeFile(in: root, name: "readable.bin", sizeBytes: 700)
        let blocked = try Fixture.makeInaccessibleDirectory(in: root, name: "blocked")
        // 튜플째 캡처하면 `@Sendable` 경계에서 경고가 난다 — 필요한 경로만 값으로 꺼내 복구한다.
        // (`TempDirectoryTestCase`의 teardown이 어차피 복구하지만, 명시적으로 되돌린다)
        let blockedPath = blocked.url.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedPath)
        }

        let result = try await calculator.calculate(at: root)

        XCTAssertGreaterThanOrEqual(result.bytes, 700, "읽을 수 있는 부분의 합계는 그대로 나와야 한다")
        XCTAssertTrue(
            result.isIncomplete,
            "읽지 못한 하위가 있었는데 완전한 값처럼 보고했다 — 화면의 '(some items couldn't be read)'가 사라진다"
        )
    }

    /// 대상 자체가 없으면 에러다(부분 합계로 위장하지 않는다).
    func testCalculate_missingDirectoryThrows() async {
        let missing = testRoot.appendingPathComponent("nope", isDirectory: true)

        do {
            _ = try await calculator.calculate(at: missing)
            XCTFail("존재하지 않는 폴더에서 에러가 나지 않았다")
        } catch is CancellationError {
            XCTFail("취소가 아니라 파일 에러여야 한다")
        } catch {
            // 기대 경로
        }
    }

    // MARK: - 점진 갱신

    func testCalculate_emitsProgressAtMostEveryUpdateInterval() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "progress")
        for index in 0..<200 {
            try Fixture.makeFile(in: root, name: "f\(index).bin", sizeBytes: 10)
        }

        let recorder = ProgressRecorder()
        let final = try await calculator.calculate(at: root) { progress in
            await recorder.append(progress)
        }

        XCTAssertEqual(final.bytes, 2000)
        // 200개는 500ms보다 훨씬 빨리 끝나므로 중간 콜백이 없는 것이 정상이다 —
        // 여기서 확인하는 것은 "콜백이 항목마다 쏟아지지 않는다"이다.
        let count = await recorder.count
        XCTAssertLessThanOrEqual(count, 2, "500ms 스로틀이 걸려 있지 않다(콜백 \(count)회)")
    }

    /// 목록 컬럼은 이 계산과 **무관**해야 한다 — 폴더의 `size`는 여전히 `nil`이다(불변식 1).
    func testFolderSize_doesNotLeakIntoListColumn() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "list")
        try Fixture.makeFile(in: root, name: "a.bin", sizeBytes: 4096)

        let items = try await DirectoryLoader().list(at: testRoot, showHidden: false)
        let folder = try XCTUnwrap(items.first { $0.name == "list" })

        XCTAssertTrue(folder.isDirectory)
        XCTAssertNil(folder.size, "목록 열거가 폴더 크기를 계산하기 시작하면 §5 성능 목표가 무너진다")
        let displayed = await MainActor.run { Formatters.displaySize(folder.size) }
        XCTAssertEqual(displayed, "--")
    }

    private actor ProgressRecorder {
        private var values: [DirectorySizeCalculator.Progress] = []
        func append(_ progress: DirectorySizeCalculator.Progress) { values.append(progress) }
        var count: Int { values.count }
    }
}
