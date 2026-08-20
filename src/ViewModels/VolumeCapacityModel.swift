import Foundation
import Observation

/// 상태바 우측의 "현재 폴더가 있는 볼륨의 여유 공간" 표시 (UI설계 §5).
///
/// **왜 창별인가**: 창마다 표시 중인 폴더가 다르고, 폴더가 속한 볼륨도 다르다.
/// 그래서 이 모델은 `AppEnvironment`(앱 전역)가 아니라 `AppModel`(창 1개분)이 소유한다.
/// 볼륨 용량 창(`DiskUsageModel`)과는 목적이 다르다 — 그쪽은 **모든 볼륨의 표**이고,
/// 이쪽은 **지금 보고 있는 한 볼륨의 한 숫자**다. 조회 규칙(어느 키가 정본인가)만
/// `VolumeService`를 통해 공유한다.
///
/// **갱신 정책 (D9의 예외)**: 용량 창은 "열 때 1회 + 수동 [Refresh]"로 못 박았다(사용자가 읽는
/// 도중 숫자가 바뀌지 않게 하려고). 상태바는 항상 보이므로 같은 규칙을 그대로 쓰면 값이
/// 영구히 낡는다 — 복사를 끝냈는데 여유 공간이 그대로면 그것이 곧 오답이다. 그래서:
///
/// - **볼륨이 바뀌면 즉시** 갱신한다(다른 디스크의 숫자를 보여주는 것은 오답이다)
/// - 같은 볼륨 안에서 폴더를 옮겨 다니는 동안은 `staleInterval` 이후에만 다시 읽는다
///   (폴더를 훑는 내내 볼륨을 stat하지 않기 위함)
/// - `⌘R`·파일 조작 완료는 **무조건** 갱신한다(사용자가 변화를 기대하는 시점이다)
/// - **타이머 폴링은 하지 않는다** — 아무 일도 없는 동안 디스크를 깨우는 비용이 표시 가치를 넘는다
@Observable
@MainActor
final class VolumeCapacityModel {

    /// 갱신을 요청한 맥락. 스로틀을 적용할지 결정하는 유일한 근거다.
    enum Reason: Sendable {
        /// 폴더 이동·최초 로드 — 같은 볼륨이면 스로틀이 걸린다.
        case navigation
        /// `⌘R`·파일 조작 완료 — 스로틀 없이 즉시 읽는다.
        case explicit
    }

    /// 같은 볼륨을 다시 읽기까지의 최소 간격.
    static let staleInterval: TimeInterval = 10

    /// 현재 표시 대상 볼륨. 볼륨을 찾지 못했으면 `nil`(표시 자체를 숨긴다).
    private(set) var volumeURL: URL?

    /// 마지막으로 읽은 용량. 조회 실패면 `nil`.
    private(set) var capacity: VolumeService.Capacity?

    /// 마지막 조회 시각 — 스로틀 판정의 기준.
    private(set) var updatedAt: Date?

    /// 상태바에 그릴 문구. `nil`이면 **아무것도 그리지 않는다**.
    ///
    /// 용량 창은 조회 실패를 `--`로 남기지만(표에서 행이 사라지면 볼륨이 없어진 것처럼 보인다),
    /// 상태바는 표가 아니라 한 줄이라 `--`가 정보를 주지 않는다 — 숨기는 쪽이 맞다.
    var displayText: String? { Self.displayText(freeBytes: capacity?.available) }

    @ObservationIgnored
    private let locator: VolumeService.VolumeLocator

    @ObservationIgnored
    private let capacityReader: VolumeService.CapacityReader

    @ObservationIgnored
    private let now: @Sendable () -> Date

    @ObservationIgnored
    private var updateTask: Task<Void, Never>?

    init(
        locator: @escaping VolumeService.VolumeLocator = VolumeService.defaultVolumeLocator,
        capacityReader: @escaping VolumeService.CapacityReader = VolumeService.defaultCapacityReader,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.capacityReader = capacityReader
        self.now = now
    }

    deinit {
        updateTask?.cancel()
    }

    /// 갱신 지점 — 폴더 이동(`.navigation`) · `⌘R`/조작 완료(`.explicit`)가 부른다.
    ///
    /// **볼륨 조회와 용량 조회를 둘 다 메인 액터 밖에서 한다** (`DiskUsageModel.refresh()`와 같은
    /// 이유): `resourceValues(forKeys:)`는 디스크에 물어보는 동기 호출이고, 응답하지 않는
    /// 마운트가 끼면 수 초까지 걸린다. 메인에서 부르면 그동안 앱 전체가 얼어붙는다
    /// (설계서 §5 "메인 블로킹 0").
    func update(for directory: URL, reason: Reason) {
        // 폴더를 빠르게 훑으면 요청이 겹친다 — 마지막 것만 남긴다(오래된 응답이 뒤늦게 덮어쓰지 않게).
        updateTask?.cancel()
        let locator = self.locator
        let reader = self.capacityReader
        let now = self.now
        let previousVolume = volumeURL
        let lastUpdatedAt = updatedAt
        updateTask = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> Outcome in
                guard let volume = locator(directory) else { return .unresolved }
                guard VolumeCapacityModel.shouldReadCapacity(
                    previousVolume: previousVolume,
                    resolvedVolume: volume,
                    lastUpdatedAt: lastUpdatedAt,
                    now: now(),
                    reason: reason
                ) else { return .unchanged }
                return .read(volume: volume, capacity: reader(volume))
            }.value

            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .unresolved:
                // 볼륨을 특정할 수 없으면 낡은 숫자를 남겨두지 않는다(다른 디스크의 값일 수 있다).
                self.volumeURL = nil
                self.capacity = nil
                self.updatedAt = nil
            case .unchanged:
                break
            case let .read(volume, capacity):
                self.volumeURL = volume
                self.capacity = capacity
                // 조회 실패(`capacity == nil`)도 시각을 남긴다 — 실패한 볼륨을 매 이동마다
                // 다시 두드리면 응답 없는 마운트에서 비용만 쌓인다.
                self.updatedAt = self.now()
            }
        }
    }

    /// 테스트가 갱신 완료를 기다리는 지점 (`DiskUsageModel.waitForRefresh()` 선례).
    func waitForUpdate() async {
        await updateTask?.value
    }

    /// 백그라운드 작업의 결과. 메인 액터로 넘어오므로 `Sendable`이어야 한다.
    private enum Outcome: Sendable {
        /// 경로가 속한 볼륨을 찾지 못했다.
        case unresolved
        /// 같은 볼륨이고 아직 신선하다 — 아무것도 바꾸지 않는다.
        case unchanged
        case read(volume: URL, capacity: VolumeService.Capacity?)
    }

    /// 용량을 다시 읽어야 하는지 — **순수 함수**라 뷰나 디스크 없이 단언할 수 있다.
    nonisolated static func shouldReadCapacity(
        previousVolume: URL?,
        resolvedVolume: URL,
        lastUpdatedAt: Date?,
        now: Date,
        reason: Reason
    ) -> Bool {
        if reason == .explicit { return true }
        // 볼륨이 바뀌었으면 스로틀과 무관하게 읽는다 — 다른 디스크의 숫자는 오답이다.
        guard let previousVolume, PathKey.isSame(previousVolume, resolvedVolume) else { return true }
        guard let lastUpdatedAt else { return true }
        return now.timeIntervalSince(lastUpdatedAt) >= staleInterval
    }

    /// 표시 문구 — `nil`이면 그리지 않는다. 순수 함수로 두어 단언 가능하게 한다.
    /// (`Formatters`가 `@MainActor`라 이 함수도 메인 액터에 남는다 — 백그라운드에서 부르지 않는다.)
    static func displayText(freeBytes: Int64?) -> String? {
        guard let freeBytes else { return nil }
        return "\(Formatters.displayByteCount(freeBytes)) free"
    }
}
