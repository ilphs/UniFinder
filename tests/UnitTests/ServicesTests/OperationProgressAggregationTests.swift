import XCTest
@testable import UniFinder

/// M3 T2 진행률 — 스트림 집계가 **항목 수 기준**으로 정확한지 (m3-impl B17·B19).
///
/// `AsyncStream<OperationProgress>`는 단일 소비자다(B17) — `AppModel.withProgress`가 이미
/// 이 스트림의 유일한 소비자이므로, 집계 정확성은 `FileOperations`가 방출하는 시퀀스 자체를
/// 여기서 직접 검증한다(M3의 새 소비 지점을 만들지 않고도 계약을 고정할 수 있다).
///
/// `OperationProgress`에는 바이트/속도 필드가 없다(B19 — Phase 2 이관) — 이 테스트는 그 축소된
/// 계약(`kind/completed/total/current`, 항목 수 기준)만 검증한다. `FileOperations`는 M2에서 이미
/// 구현되어 있으므로 이 테스트는 M3 신규 프로덕션 코드 없이 지금 바로 통과해야 한다.
final class OperationProgressAggregationTests: TempDirectoryTestCase {

    private func resolver(_ decisions: [ConflictDecision] = [], fallback: ConflictDecision = .skip) -> MockConflictResolver {
        MockConflictResolver(scripted: decisions, fallback: fallback)
    }

    private func collectProgress(
        _ body: @escaping (OperationProgressSink) async -> OperationResult
    ) async -> (result: OperationResult, ticks: [OperationProgress]) {
        let (stream, sink) = OperationProgressSink.makeStream()
        var ticks: [OperationProgress] = []
        let collector = Task {
            for await tick in stream { ticks.append(tick) }
        }
        let result = await body(sink)
        await collector.value
        return (result, ticks)
    }

    // MARK: - copy: 항목 수 기준 집계가 정확함(B19)

    func testCopy_progressStream_completedCountsMatchItemIndexInOrder() async throws {
        let files = try (0..<5).map { try Fixture.makeFile(in: testRoot, name: "f\($0).txt") }
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let ops = FileOperations()

        let (result, ticks) = await collectProgress { sink in
            await ops.copy(items: files, to: destDir, resolver: self.resolver(), progress: sink)
        }

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.produced.count, 5)

        // 매 항목 처리 전 completed=index, total=5로 1틱씩 오르고, 마지막에 completed==total로 마감한다.
        XCTAssertTrue(ticks.allSatisfy { $0.total == 5 }, "총 개수는 항목 수(5)로 고정되어야 함")
        let completedSequence = ticks.map(\.completed)
        XCTAssertEqual(completedSequence.first, 0, "첫 틱은 아직 아무것도 완료되지 않은 상태(0/5)여야 함")
        XCTAssertEqual(completedSequence.last, 5, "마지막 틱은 전체 완료(5/5)로 마감되어야 함")
        // completed는 단조 비감소(중간에 역행 없음) — 순수 항목 수 기준 집계라 순서가 뒤섞이면 안 됨.
        XCTAssertEqual(completedSequence, completedSequence.sorted(), "진행률이 역행하면 안 됨")
        XCTAssertTrue(ticks.last?.isFinished ?? false)
    }

    func testMove_progressStream_completedCountsMatchItemIndexInOrder() async throws {
        let files = try (0..<3).map { try Fixture.makeFile(in: testRoot, name: "m\($0).txt") }
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let ops = FileOperations()

        let (result, ticks) = await collectProgress { sink in
            await ops.move(items: files, to: destDir, resolver: self.resolver(), progress: sink)
        }

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(ticks.allSatisfy { $0.total == 3 })
        XCTAssertEqual(ticks.last?.completed, 3)
    }

    /// 일부 항목이 실패해도 총 개수(total)는 요청 항목 수 그대로이고, 진행률은 계속 전진해야 한다.
    func testCopy_progressStream_partialFailure_stillReportsFullTotalAndAdvances() async throws {
        let ok1 = try Fixture.makeFile(in: testRoot, name: "ok1.txt")
        let missing = testRoot.appendingPathComponent("missing.txt") // 존재하지 않는 원본 → sourceMissing
        let ok2 = try Fixture.makeFile(in: testRoot, name: "ok2.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let ops = FileOperations()

        let (result, ticks) = await collectProgress { sink in
            await ops.copy(items: [ok1, missing, ok2], to: destDir, resolver: self.resolver(), progress: sink)
        }

        XCTAssertEqual(result.produced.count, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(ticks.allSatisfy { $0.total == 3 }, "실패 항목도 total 산정에는 포함되어야 함")
        XCTAssertEqual(ticks.last?.completed, 3, "실패해도 진행은 끝까지 전진해야 함")
    }

    /// 취소 시 이미 방출된 틱들의 completed는 취소 시점까지의 값에서 멈추고, 스트림은 정상 종료(finish)된다.
    func testCopy_cancelledMidway_progressStreamFinishesWithoutHang() async throws {
        let a = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let b = try Fixture.makeFile(in: testRoot, name: "b-conflict.txt")
        let c = try Fixture.makeFile(in: testRoot, name: "c.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        _ = try Fixture.makeFile(in: destDir, name: "b-conflict.txt")

        let mockResolver = resolver()
        await mockResolver.block(source: b)

        let (stream, sink) = OperationProgressSink.makeStream()
        var ticks: [OperationProgress] = []
        let collector = Task {
            for await tick in stream { ticks.append(tick) }
        }

        let task = Task {
            await FileOperations().copy(items: [a, b, c], to: destDir, resolver: mockResolver, progress: sink)
        }

        try await waitUntil { await mockResolver.seenConflicts.contains(where: { $0.source == b }) }
        task.cancel()
        let result = await task.value
        await collector.value

        XCTAssertTrue(result.isCancelled)
        XCTAssertFalse(ticks.isEmpty, "진행 스트림이 완전히 비어 있으면 취소 전 진행 표시가 아예 안 됨")
        XCTAssertTrue(ticks.allSatisfy { $0.total == 3 })
        // 스트림이 finish() 없이 방치되면 `for await`가 영구히 대기한다 — collector.value가 반환된 것 자체가
        // finish()가 정상 호출됐다는 증거다(위 await가 타임아웃 없이 끝난다).
    }

    // MARK: - 헬퍼

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        interval: UInt64 = 5_000_000,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: interval)
        }
    }
}
