import Foundation
@testable import UniFinder

/// `ProtectedPathProbing` 테스트 더블 (m3-impl T5 / B22).
///
/// 실제 TCC 권한 상태에 의존하지 않고 3상태 판정 로직을 고정하기 위한 주입점이다
/// (M2의 `MockDirectoryListing`/`MockConflictResolver`와 동일한 패턴).
///
/// 판정 로직 자체(`evaluateStatus`)는 프로토콜 익스텐션의 프로덕션 코드를 그대로 쓴다 —
/// 더블은 "각 후보가 어떻게 관측됐는지"만 결정한다.
struct MockProtectedPathProbe: ProtectedPathProbing {

    let candidates: [ProtectedPath]

    /// 후보 순서와 1:1 대응하는 관측 결과.
    private let outcomes: [ProbeOutcome]

    /// 실제로 probe가 호출된 후보들(단축 평가 검증용).
    private let recorder: Recorder

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ProtectedPath] = []

        var probed: [ProtectedPath] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func record(_ path: ProtectedPath) {
            lock.lock()
            storage.append(path)
            lock.unlock()
        }
    }

    var probedPaths: [ProtectedPath] { recorder.probed }

    /// - Parameter outcomes: 후보 순서대로의 관측 결과. 후보 URL은 자동 생성된다.
    init(_ outcomes: [ProbeOutcome]) {
        self.outcomes = outcomes
        self.candidates = outcomes.indices.map { .directory("/probe/candidate-\($0)") }
        self.recorder = Recorder()
    }

    /// 경로를 직접 지정해야 하는 경우(실제 파일시스템 프로브와 혼합 검증)용.
    init(candidates: [ProtectedPath], outcomes: [ProbeOutcome]) {
        precondition(candidates.count == outcomes.count, "후보와 관측 결과 개수가 달라 판정이 모호해진다")
        self.candidates = candidates
        self.outcomes = outcomes
        self.recorder = Recorder()
    }

    func probe(_ candidate: ProtectedPath) -> ProbeOutcome {
        recorder.record(candidate)
        guard let index = candidates.firstIndex(of: candidate) else { return .inconclusive }
        return outcomes[index]
    }
}
