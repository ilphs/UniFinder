import Foundation
import Observation

/// 파일 조작 진행 상태 (m3-impl T2 / UI설계 §7.4).
///
/// **비모달 오버레이 전용 상태다** (B18): 진행률을 시트로 띄우면 같은 윈도우의 충돌 시트가
/// AppKit 시트 큐에 밀려 표시되지 않고, 조작은 그 응답을 기다리며 멈춘다. 그래서 이 모델은
/// 윈도우 콘텐츠 안에 그려지는 오버레이의 상태만 들고 있고, 어떤 모달 세션도 열지 않는다.
///
/// **항목 수 기준만 표시한다** (B19): `OperationProgress`에는 바이트 필드가 없고
/// `FileManager.copyItem`은 단일 대용량 파일 복사 중 콜백을 주지 않는다. 바이트·속도 표시는
/// 청크 복사 + 사전 크기 스캔이 필요해 Phase 2로 이관했다.
///
/// **지연 표시**: `DirectoryModel`의 200ms 스피너 패턴을 그대로 재사용하되, 임계는 1초다.
/// 소용량 작업(대부분)에서는 오버레이가 아예 나타나지 않아 깜빡임이 없다.
@Observable
@MainActor
final class OperationProgressModel {

    /// 이 시간을 넘겨 지속되는 작업만 오버레이를 띄운다 (UI설계 §7.4).
    /// (기본 인자에서 참조하므로 `nonisolated` — MainActor 격리 상수는 기본값 위치에서 읽을 수 없다)
    nonisolated static let presentationDelay: Duration = .seconds(1)

    /// 오버레이 표시 여부. 작업 시작 즉시가 아니라 `presentationDelay` 이후에 켜진다.
    private(set) var isVisible = false

    private(set) var kind: FileOperationKind?
    private(set) var completed: Int = 0
    private(set) var total: Int = 0
    /// 현재 처리 중인 항목 이름 (UI설계 §7.4 — 파일명 표시).
    private(set) var currentName: String?
    /// 취소를 눌렀지만 진행 중 항목이 끝나기를 기다리는 상태 (취소 의미론: 진행 중 항목 완료 후 중단).
    private(set) var isCancelling = false

    @ObservationIgnored
    private var delayTask: Task<Void, Never>?

    @ObservationIgnored
    private let presentationDelay: Duration

    init(presentationDelay: Duration = OperationProgressModel.presentationDelay) {
        self.presentationDelay = presentationDelay
    }

    // MARK: - 표시 문구

    var title: String { kind?.progressLabel ?? "" }

    /// 항목 수 기준 진행 문구 (B19 — 바이트·속도는 Phase 2).
    var itemCountText: String {
        guard total > 0 else { return "" }
        return "\(min(completed, total))/\(total) 항목"
    }

    /// 0~1. 총 개수를 모르면 `nil`(불확정 막대).
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    // MARK: - 수명주기 (AppModel.withProgress가 유일한 호출자 — B17)

    /// 조작 시작. 오버레이는 아직 띄우지 않고 지연 타이머만 건다.
    func begin(kind: FileOperationKind) {
        delayTask?.cancel()
        self.kind = kind
        completed = 0
        total = 0
        currentName = nil
        isCancelling = false
        isVisible = false

        let delay = presentationDelay
        delayTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.kind != nil else { return }
            self.isVisible = true
        }
    }

    /// 진행 틱 반영. 스트림의 유일한 소비자(`AppModel.withProgress`)만 호출한다.
    func update(_ progress: OperationProgress) {
        kind = progress.kind
        completed = progress.completed
        total = progress.total
        currentName = progress.current?.lastPathComponent
    }

    /// 취소 요청을 눌렀다 — 실제 종료는 진행 중 항목이 끝난 뒤다.
    func markCancelling() {
        guard kind != nil else { return }
        isCancelling = true
    }

    /// 조작 종료(성공/실패/취소 공통). 지연 타이머가 아직 살아 있으면 오버레이는 끝내 뜨지 않는다.
    func finish() {
        delayTask?.cancel()
        delayTask = nil
        isVisible = false
        isCancelling = false
        kind = nil
        completed = 0
        total = 0
        currentName = nil
    }
}
