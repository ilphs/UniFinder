import Foundation

/// semver 버전 — 업데이트 확인의 "새 버전인가" 판정 근거 (후속 T3 / D4).
///
/// **문자열 비교를 절대 쓰지 않는 이유**: `"0.10.0" < "0.9.0"`이 참이 된다(문자 `1` < `9`).
/// 즉 0.9.0 사용자가 0.10.0 릴리스를 영영 안내받지 못한다. 숫자 튜플로 비교해야 한다.
///
/// 다루는 형태:
/// - `v` 접두는 제거한다 (GitHub 태그 관례가 `v0.3.4`다)
/// - `major.minor.patch` 3자리 기준. 자리가 모자라면 0으로 채운다(`0.3` → `0.3.0`)
/// - `-prerelease`와 `+build` 메타데이터를 인식한다. **빌드 메타데이터는 비교에서 무시**한다(semver 규칙)
/// - 해석할 수 없으면 `nil` — 호출자는 "비교 불가"로 다루고 조용히 넘어간다(D4: 자동 확인은 침묵)
struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible {

    let major: Int
    let minor: Int
    let patch: Int
    /// `-` 뒤의 프리릴리스 식별자들(`1.0.0-beta.2` → `["beta", "2"]`). 정식 릴리스는 빈 배열.
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// - Returns: 해석 실패 시 `nil`. 빈 문자열·문자만 있는 태그(`latest`)·음수는 전부 실패다.
    init?(_ rawValue: String) {
        var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // GitHub 태그 관례: `v0.3.4` / `V0.3.4`
        if let first = text.first, first == "v" || first == "V" {
            text.removeFirst()
        }

        // 빌드 메타데이터는 비교에 관여하지 않는다 (semver §10).
        if let plus = text.firstIndex(of: "+") {
            text = String(text[..<plus])
        }

        var prereleaseParts: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let tail = String(text[text.index(after: dash)...])
            prereleaseParts = tail.split(separator: ".").map(String.init)
            text = String(text[..<dash])
        }

        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !numbers.isEmpty, numbers.count <= 3 else { return nil }

        var parsed: [Int] = []
        for component in numbers {
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let value = Int(component)
            else { return nil }
            parsed.append(value)
        }

        self.major = parsed[0]
        self.minor = parsed.count > 1 ? parsed[1] : 0
        self.patch = parsed.count > 2 ? parsed[2] : 0
        self.prerelease = prereleaseParts.filter { !$0.isEmpty }
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    // MARK: - Comparable

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // semver §11.3 — 프리릴리스가 붙은 쪽이 **낮다**. 1.0.0-beta < 1.0.0
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): return comparePrerelease(lhs.prerelease, rhs.prerelease)
        }
    }

    /// 프리릴리스 식별자 비교 (semver §11.4): 숫자 식별자는 수치로, 그 외는 사전순.
    /// 숫자 식별자는 비숫자 식별자보다 항상 낮고, 앞이 모두 같으면 식별자가 적은 쪽이 낮다.
    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Bool {
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            guard left != right else { continue }

            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.count < rhs.count
    }
}
