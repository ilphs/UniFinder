import Foundation
import Observation

/// 업데이트 확인의 영속 상태 (후속 T3 / D10).
///
/// **`AppSettings`와 분리한 이유**: `AppSettings`는 "사용자가 화면에서 만든 상태"(숨김·정렬·
/// 즐겨찾기·폭)의 저장소다. 여기 들어가는 값은 성격이 다르다 — ETag 캐시나 마지막 확인 시각은
/// 사용자가 만든 것이 아니라 **네트워크 대화의 부산물**이고, 업데이트 기능을 걷어내면 통째로
/// 사라져야 하는 값이다. 한 클래스에 섞으면 그 경계가 흐려진다.
///
/// **별도 `UserDefaults` suite를 만들지 않는다**(D10). suite를 나누면 앱 설정이 두 파일로
/// 흩어져 백업·초기화 절차가 갈라진다. `.standard`에 `update.` 접두사만 붙인다.
///
/// 저장 규약은 `AppSettings`와 동일하다: `private enum Key` + `didSet` 즉시 기록.
@Observable
@MainActor
final class UpdatePreferences {

    private enum Key {
        static let autoCheckEnabled = "update.autoCheckEnabled"
        static let lastCheckedAt = "update.lastCheckedAt"
        static let skippedVersion = "update.skippedVersion"
        static let cachedETag = "update.cachedETag"
        static let cachedLatestVersion = "update.cachedLatestVersion"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    /// 앱 시작 시 자동 확인을 할지. **기본값은 켬**이지만 사용자가 끌 수 있다
    /// (설계서 §1.2 네트워크 예외의 경계 (d) — "사용자가 끌 수 있다"가 예외의 조건 중 하나다).
    var autoCheckEnabled: Bool {
        didSet { defaults.set(autoCheckEnabled, forKey: Key.autoCheckEnabled) }
    }

    /// 마지막으로 **성공적으로 확인한** 시각. 24시간 스로틀의 기준.
    ///
    /// 실패한 확인은 여기를 갱신하지 않는다 — 갱신하면 네트워크가 잠깐 끊긴 사용자가
    /// 그 뒤 24시간 동안 자동 확인을 통째로 잃는다.
    var lastCheckedAt: Date? {
        didSet {
            if let lastCheckedAt {
                defaults.set(lastCheckedAt.timeIntervalSinceReferenceDate, forKey: Key.lastCheckedAt)
            } else {
                defaults.removeObject(forKey: Key.lastCheckedAt)
            }
        }
    }

    /// 사용자가 [Skip This Version]을 누른 버전. **자동 확인만** 침묵시킨다.
    var skippedVersion: String? {
        didSet {
            if let skippedVersion {
                defaults.set(skippedVersion, forKey: Key.skippedVersion)
            } else {
                defaults.removeObject(forKey: Key.skippedVersion)
            }
        }
    }

    /// 마지막 응답의 `ETag`. 다음 요청의 `If-None-Match`로 보내 304를 받으면 본문 전송이 없다.
    var cachedETag: String? {
        didSet {
            if let cachedETag {
                defaults.set(cachedETag, forKey: Key.cachedETag)
            } else {
                defaults.removeObject(forKey: Key.cachedETag)
            }
        }
    }

    /// ETag가 304를 돌려줬을 때 되살릴 마지막 성공 결과의 버전 문자열.
    /// (304는 본문이 없으므로 캐시가 없으면 "확인했지만 아무것도 모르는" 상태가 된다)
    var cachedLatestVersion: String? {
        didSet {
            if let cachedLatestVersion {
                defaults.set(cachedLatestVersion, forKey: Key.cachedLatestVersion)
            } else {
                defaults.removeObject(forKey: Key.cachedLatestVersion)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 키 부재 = 최초 실행 → 기본 켬. `bool(forKey:)`는 부재를 false로 뭉개므로 object로 본다.
        self.autoCheckEnabled = (defaults.object(forKey: Key.autoCheckEnabled) as? Bool) ?? true

        if let stamp = defaults.object(forKey: Key.lastCheckedAt) as? Double {
            self.lastCheckedAt = Date(timeIntervalSinceReferenceDate: stamp)
        } else {
            self.lastCheckedAt = nil
        }

        self.skippedVersion = defaults.string(forKey: Key.skippedVersion)
        self.cachedETag = defaults.string(forKey: Key.cachedETag)
        self.cachedLatestVersion = defaults.string(forKey: Key.cachedLatestVersion)
    }

    // MARK: - 스로틀 / 침묵 판정

    /// 자동 확인 간격 — 24시간 (D4).
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    /// 지금 **자동** 확인을 해도 되는지. 수동 확인은 이 판정을 거치지 않는다.
    /// - Parameter now: 테스트가 시간을 고정할 수 있게 주입한다.
    func shouldAutoCheck(now: Date = Date()) -> Bool {
        guard autoCheckEnabled else { return false }
        guard let lastCheckedAt else { return true }
        // 시계가 뒤로 간 경우(시간대 변경·수동 조정)도 확인을 막지 않는다.
        let elapsed = now.timeIntervalSince(lastCheckedAt)
        return elapsed < 0 || elapsed >= Self.automaticCheckInterval
    }

    /// 이 버전을 **자동** 확인에서 침묵시켜야 하는지.
    func isSkipped(_ version: SemanticVersion) -> Bool {
        guard let skippedVersion, let parsed = SemanticVersion(skippedVersion) else { return false }
        // 문자열이 아니라 값으로 비교한다 — `v0.4.0`과 `0.4.0`은 같은 버전이다.
        return parsed == version
    }

    func skip(_ version: SemanticVersion) {
        skippedVersion = version.description
    }
}
