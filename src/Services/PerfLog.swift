import Foundation
import os

/// 성능 계측(T8). Instruments의 os_signpost 트랙에 "폴더 열기 → 첫 표시" 구간을 남기고,
/// 콘솔에서도 확인할 수 있도록 소요 시간을 로그로 출력한다.
///
/// `UNIFINDER_PERF_LOG=1` 환경변수를 켜면 stdout으로도 찍는다(터미널 측정용).
enum PerfLog {

    static let subsystem = "com.unifinder.app"

    static let logger = Logger(subsystem: subsystem, category: "Performance")
    static let signposter = OSSignposter(subsystem: subsystem, category: "Performance")

    private static let stdoutEnabled: Bool = {
        ProcessInfo.processInfo.environment["UNIFINDER_PERF_LOG"] == "1"
    }()

    struct LoadState {
        let signpostID: OSSignpostID
        let interval: OSSignpostIntervalState
        let started: ContinuousClock.Instant
    }

    static func beginDirectoryLoad(_ url: URL) -> LoadState {
        let id = signposter.makeSignpostID()
        let interval = signposter.beginInterval("DirectoryLoad", id: id)
        return LoadState(signpostID: id, interval: interval, started: .now)
    }

    static func endDirectoryLoad(_ state: LoadState, url: URL, itemCount: Int) {
        signposter.endInterval("DirectoryLoad", state.interval)
        let elapsed = ContinuousClock.now - state.started
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        // 사용자가 방문한 폴더 경로는 프라이버시 정보다 — 통합 로그에 평문으로 남기지 않는다.
        // (소요 시간·항목 수 같은 비민감 계측값만 public)
        logger.log("첫 표시 \(milliseconds, format: .fixed(precision: 1))ms · \(itemCount)개 · \(url.path, privacy: .private)")
        if stdoutEnabled {
            print(String(format: "[perf] first-display %.1fms items=%d path=%@", milliseconds, itemCount, url.path))
        }
    }

    static func cancelDirectoryLoad(_ state: LoadState, url: URL) {
        signposter.endInterval("DirectoryLoad", state.interval)
    }
}
