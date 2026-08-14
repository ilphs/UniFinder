import Foundation
@testable import UniFinder

/// `FileOperating` 테스트 더블 — 시점을 정밀 제어해야 하는 M3 T2(진행률·취소)/T3(D&D) 테스트 전용.
///
/// `FileOperations`(actor, 실 파일시스템)는 타이밍을 결정적으로 제어하기 어렵다
/// (`MockDirectoryListing`의 게이트 패턴을 `FileOperating`에 맞게 재사용한다).
/// - `hold()`로 `move`/`copy` 진행을 도중에 멈춰두고, `release()`로 재개시킬 수 있다.
/// - 취소되면 `withTaskCancellationHandler`로 대기 중 continuation을 반드시 재개한다
///   (M2 `MockConflictResolver`와 같은 안전성 계약).
actor GatedFileOperating: FileOperating {

    private(set) var moveCallCount = 0
    private(set) var copyCallCount = 0
    private(set) var trashCallCount = 0
    private(set) var lastMoveDestination: URL?
    private(set) var lastCopyDestination: URL?

    /// 대기 중 취소로 인해 continuation이 재개된 횟수 (행/누수 없음을 확인하는 용도).
    private(set) var cancellationResumedCount = 0

    private var isGated = false
    private var gateContinuation: CheckedContinuation<Void, Never>?

    private var scriptedResult = OperationResult()
    private var scriptedProgress: [OperationProgress] = []

    func setGated(_ gated: Bool) {
        isGated = gated
    }

    func release() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func configureResult(_ result: OperationResult) {
        scriptedResult = result
    }

    /// 항목 단위 진행 틱을 명시적으로 지정한다 (item-count 집계 검증용). 비어 있으면 방출하지 않는다.
    func configureProgress(_ ticks: [OperationProgress]) {
        scriptedProgress = ticks
    }

    func copy(
        items: [URL],
        to destination: URL,
        resolver: any ConflictResolving,
        progress: OperationProgressSink?
    ) async -> OperationResult {
        copyCallCount += 1
        lastCopyDestination = destination
        for tick in scriptedProgress { progress?.send(tick) }
        await waitIfGated()
        progress?.finish()
        return scriptedResult
    }

    func move(
        items: [URL],
        to destination: URL,
        resolver: any ConflictResolving,
        progress: OperationProgressSink?
    ) async -> OperationResult {
        moveCallCount += 1
        lastMoveDestination = destination
        for tick in scriptedProgress { progress?.send(tick) }
        await waitIfGated()
        progress?.finish()
        return scriptedResult
    }

    func trash(items: [URL], progress: OperationProgressSink?) async -> OperationResult {
        trashCallCount += 1
        progress?.finish()
        return scriptedResult
    }

    func rename(item: URL, to newName: String) async -> OperationResult {
        scriptedResult
    }

    func createFolder(in parent: URL, name: String) async -> OperationResult {
        scriptedResult
    }

    private func waitIfGated() async {
        guard isGated else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                gateContinuation = cont
            }
        } onCancel: {
            Task { await self.resumeOnCancel() }
        }
    }

    private func resumeOnCancel() {
        guard let cont = gateContinuation else { return }
        gateContinuation = nil
        cancellationResumedCount += 1
        cont.resume()
    }
}
