import Foundation

/// 앱 버전 문자열의 **단일 진입점** (후속 T0 — 버전 소스 단일화).
///
/// 버전은 세 곳에 흩어져 있었다: `project.yml`의 `MARKETING_VERSION`, 생성된 pbxproj,
/// `README.md`의 안내 표. 정본은 **`project.yml`의 `MARKETING_VERSION` 하나**이고,
/// 나머지는 그것을 따라간다(`VersionSourceConsistencyTests`가 어긋남을 빌드 게이트에서 잡는다).
///
/// 런타임에서는 그 값이 빌드 시 `Info.plist`의 `CFBundleShortVersionString`으로 굳으므로
/// 여기서 번들을 읽는다. **코드 어디에도 버전 리터럴을 두지 않는다** — 업데이트 확인
/// (`UpdateChecker`)이 "현재 버전"을 물을 때도 이 진입점만 쓴다.
enum AppVersion {

    /// `CFBundleShortVersionString` (예: `0.3.4`). 번들에 없으면 `"0.0.0"`.
    ///
    /// 폴백이 `"0.0.0"`인 이유: 파싱 실패로 크래시하거나 업데이트 확인이 죽는 것보다,
    /// "무조건 구버전"으로 판정돼 사용자가 최신 릴리스를 안내받는 편이 안전하다.
    /// (단위 테스트 번들에서 앱 번들을 읽지 못하는 경우도 이 경로를 탄다)
    static var current: String {
        marketingVersion(from: .main) ?? fallback
    }

    /// `SemanticVersion`으로 해석한 현재 버전. 파싱 불가면 `0.0.0`.
    static var currentSemantic: SemanticVersion {
        SemanticVersion(current) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }

    static let fallback = "0.0.0"

    /// 번들 주입 가능한 형태 — 테스트가 임의 번들/누락 상황을 재현한다.
    static func marketingVersion(from bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return value
    }
}
