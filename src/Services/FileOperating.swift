import Foundation

/// 충돌 질의 추상화 (m2-impl T0 / architect B4).
///
/// M1의 `DirectoryListing`과 **같은 주입 패턴**이다. `FileOperations`(actor)는 이 프로토콜만
/// 알고 UI를 직접 호출하지 않으므로 설계서 §3.1의 의존 방향(Services → UI 금지)이 유지되고,
/// 테스트는 결정적인 mock을 꽂아 충돌 3분기를 재현할 수 있다.
///
/// 프레젠터는 `@MainActor`로 구현한다(시트 표시). `async` 요구사항이므로 액터 경계는
/// 호출 지점에서 자연스럽게 넘어간다 — 스트림+콜백을 손으로 묶지 않는다.
protocol ConflictResolving: Sendable {

    /// - Returns: 이 충돌에 대한 처리 방법 + "남은 항목에 모두 적용" 여부.
    ///   호출자(`FileOperations`)가 취소되면 구현체는 **반드시** 대기 중인 continuation을
    ///   재개시켜야 한다(`withTaskCancellationHandler`) — 아니면 작업이 영구히 행 상태로 남는다.
    func resolve(_ conflict: FileConflict) async -> ConflictDecision
}

/// 충돌이 나면 무조건 지정한 결정을 돌려주는 기본 구현.
/// (충돌 UI가 없는 경로 — 새 폴더 생성, 프로그램적 호출 — 에서 쓴다)
struct FixedConflictResolver: ConflictResolving {

    let decision: ConflictDecision

    init(_ resolution: ConflictResolution) {
        self.decision = ConflictDecision(resolution: resolution, applyToAll: true)
    }

    func resolve(_ conflict: FileConflict) async -> ConflictDecision { decision }
}

/// 진행 상황 방출구. `AsyncStream`의 continuation을 감싸 Services가 UI 타입을 모르게 한다.
///
/// M2는 상태바 미니 표시만 소비하고, M3의 진행률 시트가 같은 스트림을 재사용한다.
struct OperationProgressSink: Sendable {

    private let continuation: AsyncStream<OperationProgress>.Continuation

    init(continuation: AsyncStream<OperationProgress>.Continuation) {
        self.continuation = continuation
    }

    func send(_ progress: OperationProgress) {
        continuation.yield(progress)
    }

    func finish() {
        continuation.finish()
    }

    /// 진행 스트림 + 방출구 한 쌍을 만든다.
    static func makeStream() -> (stream: AsyncStream<OperationProgress>, sink: OperationProgressSink) {
        var captured: AsyncStream<OperationProgress>.Continuation!
        let stream = AsyncStream<OperationProgress>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            captured = continuation
        }
        return (stream, OperationProgressSink(continuation: captured))
    }
}

/// 파일 조작 서비스 추상화 (m2-impl T0 / architect B1 — `AppModel`이 주입받는 지점).
///
/// 모든 연산은 **항목 단위 순회**(설계 결정 #4)로 수행하고, 일부 항목이 실패해도 나머지를
/// 계속 처리한 뒤 실패 목록을 결과에 담아 돌려준다. 예외를 던지지 않는 이유는
/// "3개 중 1개 실패"가 정상 흐름이기 때문이다.
protocol FileOperating: Sendable {

    func copy(
        items: [URL],
        to destination: URL,
        resolver: any ConflictResolving,
        progress: OperationProgressSink?
    ) async -> OperationResult

    func move(
        items: [URL],
        to destination: URL,
        resolver: any ConflictResolving,
        progress: OperationProgressSink?
    ) async -> OperationResult

    func trash(items: [URL], progress: OperationProgressSink?) async -> OperationResult

    func rename(item: URL, to newName: String) async -> OperationResult

    func createFolder(in parent: URL, name: String) async -> OperationResult
}

extension FileOperating {

    func copy(items: [URL], to destination: URL, resolver: any ConflictResolving) async -> OperationResult {
        await copy(items: items, to: destination, resolver: resolver, progress: nil)
    }

    func move(items: [URL], to destination: URL, resolver: any ConflictResolving) async -> OperationResult {
        await move(items: items, to: destination, resolver: resolver, progress: nil)
    }

    func trash(items: [URL]) async -> OperationResult {
        await trash(items: items, progress: nil)
    }

    /// 중복이면 `새 폴더 2`, `새 폴더 3` … 으로 자동 넘버링해 만든다 (m2-impl T6).
    ///
    /// `createFolder(in:name:)`는 중복을 `.nameExists`로 거부하는 원시 연산이므로,
    /// "연속 생성 시 넘버링" 요구사항은 이 래퍼가 담당한다.
    func createFolder(in parent: URL, uniqueBaseName base: String) async -> OperationResult {
        var result = await createFolder(in: parent, name: base)
        var index = 2
        while result.failures.first?.error == .nameExists, index <= 1000 {
            result = await createFolder(in: parent, name: "\(base) \(index)")
            index += 1
        }
        return result
    }
}
