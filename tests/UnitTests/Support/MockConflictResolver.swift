import Foundation
@testable import UniFinder

/// `ConflictResolving`(m2-impl.md T0/B4, `src/Services/FileOperating.swift`) 준수 테스트 더블.
///
/// `FileOperations`(actor)가 충돌마다 `resolve(_:)`를 await하므로, 이 더블은
/// - 미리 정해둔 결정을 순서대로 돌려주는 스크립트 모드
/// - 취소 시 `withTaskCancellationHandler`로 대기 중 continuation이 반드시 재개되는지
///   검증하기 위한 "블로킹" 모드
/// 두 가지를 지원한다.
actor MockConflictResolver: ConflictResolving {

    private(set) var seenConflicts: [FileConflict] = []
    private var scriptedDecisions: [ConflictDecision]
    /// 스크립트가 소진된 뒤 추가 충돌이 들어오면 사용할 기본값.
    private let fallback: ConflictDecision

    /// `resolve(_:)`가 값을 반환하기 전에 잠시 멈춰야 하는 대상(source URL). 이 URL에 대한
    /// 충돌이 오면 `unblock()`이 불리거나 호출자의 Task가 취소될 때까지 suspend한다.
    private var blockedSources: Set<URL> = []
    private var pendingContinuations: [URL: CheckedContinuation<ConflictDecision, Never>] = [:]

    /// 취소로 인해 continuation이 재개된 횟수. "행/누수 없음"을 확인하는 용도.
    private(set) var cancellationResumedCount = 0

    init(scripted decisions: [ConflictDecision] = [], fallback: ConflictDecision = .skip) {
        self.scriptedDecisions = decisions
        self.fallback = fallback
    }

    /// 이 source에 대한 충돌 질의가 오면 `unblock(_:)`까지 응답을 보류한다.
    func block(source: URL) {
        blockedSources.insert(source)
    }

    /// 보류 중인 충돌에 결정을 내려 재개시킨다.
    func unblock(source: URL, with decision: ConflictDecision) {
        blockedSources.remove(source)
        if let cont = pendingContinuations.removeValue(forKey: source) {
            cont.resume(returning: decision)
        }
    }

    func resolve(_ conflict: FileConflict) async -> ConflictDecision {
        seenConflicts.append(conflict)

        if blockedSources.contains(conflict.source) {
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<ConflictDecision, Never>) in
                    pendingContinuations[conflict.source] = cont
                }
            } onCancel: {
                Task { await self.resumeOnCancel(conflict.source) }
            }
        }

        guard !scriptedDecisions.isEmpty else { return fallback }
        return scriptedDecisions.removeFirst()
    }

    private func resumeOnCancel(_ source: URL) {
        guard let cont = pendingContinuations.removeValue(forKey: source) else { return }
        cancellationResumedCount += 1
        cont.resume(returning: .cancel)
    }
}
