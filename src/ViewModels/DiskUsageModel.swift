import Foundation
import Observation

/// 디스크 용량 창의 상태 (후속 T8 / UI설계 §7.7 · D1 · D9).
///
/// **볼륨 목록은 사이드바와 같은 `VolumeService`를 쓴다**(T1) — 두 화면이 서로 다른 볼륨을
/// 보여주면 "사이드바에는 있는데 용량 창에는 없다"가 곧바로 버그로 보고된다.
/// 따라서 네트워크 볼륨은 여기서도 제외된다(설계서 §1.2).
///
/// **갱신은 열 때 1회 + 수동 [Refresh]뿐이다**(D9). 마운트/언마운트 통지를 구독하지 않는다 —
/// 용량 값은 초 단위로 흔들리는데 자동 갱신은 사용자가 읽는 도중 숫자를 바꿔 놓는다.
/// 대신 `updatedAt`을 항상 표시해 값의 나이를 숨기지 않는다.
@Observable
@MainActor
final class DiskUsageModel {

    /// 볼륨 1개의 표시 값.
    struct Volume: Identifiable, Equatable, Sendable {
        let url: URL
        let name: String
        /// 전체 용량. 조회 실패면 `nil` → 화면에 `--`.
        let totalBytes: Int64?
        /// 여유 공간. 조회 실패면 `nil`.
        let availableBytes: Int64?

        var id: String { url.path }

        /// 사용량 — **`max(0, total - available)`로 클램프한다**(D1).
        ///
        /// `volumeAvailableCapacityForImportantUsage`는 "정리 가능한 공간까지 포함하면 이만큼 쓸 수
        /// 있다"는 값이라 `volumeTotalCapacity`보다 클 수 있다. 클램프하지 않으면 사용량이 음수로
        /// 표시되는데, 음수 사용량은 사용자에게 아무 의미가 없다.
        var usedBytes: Int64? {
            guard let totalBytes, let availableBytes else { return nil }
            return max(0, totalBytes - availableBytes)
        }

        /// 사용 비율 0...1. 계산 불가면 `nil`(막대를 그리지 않는다).
        var usedFraction: Double? {
            guard let totalBytes, totalBytes > 0, let usedBytes else { return nil }
            return min(1.0, Double(usedBytes) / Double(totalBytes))
        }

        /// 여유가 10% 미만이면 경고색 (UI설계 §7.7).
        var isLowOnSpace: Bool {
            guard let totalBytes, totalBytes > 0, let availableBytes else { return false }
            return Double(availableBytes) / Double(totalBytes) < Self.lowSpaceThreshold
        }

        static let lowSpaceThreshold = 0.10
    }

    private(set) var volumes: [Volume] = []
    /// 마지막 갱신 시각 — `Updated HH:mm`으로 표시한다(값의 나이를 숨기지 않는다).
    private(set) var updatedAt: Date?

    @ObservationIgnored
    private let volumeService: VolumeService

    /// 용량 조회 주입점 — 테스트가 실제 디스크 상태에 묶이지 않게 한다
    /// (`FullDiskAccessModel.opener` 선례). `nil`을 돌려주면 "조회 실패"다.
    typealias CapacityReader = @Sendable (_ url: URL) -> Capacity?

    struct Capacity: Sendable, Equatable {
        var total: Int64?
        var available: Int64?
    }

    @ObservationIgnored
    private let capacityReader: CapacityReader

    @ObservationIgnored
    private let now: @Sendable () -> Date

    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    init(
        volumeService: VolumeService = VolumeService(),
        capacityReader: @escaping CapacityReader = DiskUsageModel.defaultCapacityReader,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.volumeService = volumeService
        self.capacityReader = capacityReader
        self.now = now
    }

    deinit {
        refreshTask?.cancel()
    }

    /// 창을 열 때 1회 + [Refresh]가 부르는 유일한 갱신 지점.
    ///
    /// **열거·용량 조회는 메인 액터 밖에서 한다** (reviewer major #4 / `ItemInfoModel.load()`와 같은 패턴).
    /// `VolumeService.localVolumes()`의 볼륨 열거와 `resourceValues(forKeys:)`는 둘 다 디스크에 물어보는 동기 호출이고,
    /// 응답하지 않는 외장/네트워크 마운트가 하나라도 끼면 **수 초까지** 걸릴 수 있다. 메인 액터에서
    /// 부르면 그동안 앱 전체(다른 창의 탐색까지)가 얼어붙는다 — 설계서 §5의 "메인 블로킹 0" 위반.
    ///
    /// 반영은 메인 액터에서, 완성된 배열 하나를 통째로 대입한다(중간 상태를 화면에 보이지 않는다).
    func refresh() {
        // 사용자가 [Refresh]를 연타해도 마지막 것만 남는다 — 오래된 응답이 뒤늦게 덮어쓰지 않게.
        refreshTask?.cancel()
        let service = volumeService
        let reader = capacityReader
        refreshTask = Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                DiskUsageModel.collect(service: service, capacityReader: reader)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.volumes = loaded
            self.updatedAt = self.now()
        }
    }

    /// 테스트가 갱신 완료를 기다리는 지점 (`ItemInfoModel.waitForLoad()` 선례).
    func waitForRefresh() async {
        await refreshTask?.value
    }

    /// 볼륨 열거 + 용량 조회 + 정렬. **`nonisolated`**라 백그라운드에서 그대로 돈다.
    ///
    /// 볼륨 속성은 `localVolumes()`가 이미 읽어 왔으므로 이름을 얻으려고 다시 조회하지 않는다
    /// (예전에는 `displayName(of:)`이 볼륨마다 같은 조회를 한 번 더 했다).
    nonisolated static func collect(service: VolumeService, capacityReader: CapacityReader) -> [Volume] {
        service.localVolumes()
            .map { volume in
                let capacity = capacityReader(volume.url)
                return Volume(
                    url: volume.url,
                    name: volume.displayName,
                    totalBytes: capacity?.total,
                    availableBytes: capacity?.available
                )
            }
            // 루트 볼륨을 맨 위에 두고 나머지는 이름순 — 사용자가 매번 같은 자리에서 찾게 한다.
            .sorted { left, right in
                if (left.url.path == "/") != (right.url.path == "/") { return left.url.path == "/" }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    /// D1 — 여유 공간은 `forImportantUsage`가 정본이고, 없으면 `volumeAvailableCapacity`로 폴백한다.
    ///
    /// 두 키의 의미가 다르다: 전자는 "정리 가능한 공간을 포함해 실제로 쓸 수 있는 양"이고
    /// 후자는 "지금 당장 비어 있는 양"이다. Finder가 보여주는 값은 전자에 가깝다.
    nonisolated static let defaultCapacityReader: CapacityReader = { url in
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        // `forImportantUsage`는 이미 `Int64?`, 나머지는 `Int?`라 타입을 명시적으로 맞춘다.
        let important: Int64? = values.volumeAvailableCapacityForImportantUsage
        let fallback: Int64? = values.volumeAvailableCapacity.map { Int64($0) }
        let total: Int64? = values.volumeTotalCapacity.map { Int64($0) }
        return Capacity(total: total, available: important ?? fallback)
    }
}
