import Foundation

/// 빌드 구성(서명·hardened runtime·테스트 타깃)을 **소스에서 직접 읽는** 테스트 지원 타입.
///
/// 이런 항목은 코드가 아니라 빌드 설정에 있어서 단위 테스트로 잡히지 않고, "릴리스 직전에
/// 사람이 기억해서 켜는" 절차 문제로 남는다. 절차를 자동 게이트로 바꾸기 위해 두 곳을 함께 본다:
///
/// - `project.yml` — 사람이 고치는 **원본**
/// - `UniFinder.xcodeproj/project.pbxproj` — xcodebuild가 실제로 소비하는 **생성물**
///   (원본만 보면 "고쳤지만 `xcodegen generate`를 안 돌린" 상태를 통과시킨다)
///
/// 경로는 `#filePath` 기준으로 잡는다 — 테스트 번들은 소스 트리를 담지 않기 때문이다.
/// (CI 없이 로컬 체크아웃에서만 도는 프로젝트라는 전제. 테스트계획 §1 "실행" 참조)
enum ProjectManifest {

    /// 저장소 루트 (`<root>/tests/UnitTests/Support/ProjectManifest.swift` 기준).
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // UnitTests
            .deletingLastPathComponent() // tests
            .deletingLastPathComponent() // <root>
    }

    static var projectYAMLURL: URL {
        repositoryRoot.appendingPathComponent("project.yml")
    }

    static var pbxprojURL: URL {
        repositoryRoot
            .appendingPathComponent("UniFinder.xcodeproj")
            .appendingPathComponent("project.pbxproj")
    }

    // MARK: - project.yml

    /// `project.yml`을 `a.b.c` 형태의 평탄한 키/값 사전으로 읽는다.
    ///
    /// 정식 YAML 파서를 붙이지 않는 이유: 테스트가 보는 영역은 들여쓰기 2칸의 단순 맵뿐이고,
    /// 의존성을 늘리지 않기 위해서다. 배열 항목(`- path: src`)은 관심 밖이라 건너뛴다.
    static func projectSettings() throws -> [String: String] {
        let text = try String(contentsOf: projectYAMLURL, encoding: .utf8)
        return flatten(text)
    }

    static func flatten(_ yaml: String) -> [String: String] {
        var result: [String: String] = [:]
        var stack: [(indent: Int, key: String)] = []

        for rawLine in yaml.components(separatedBy: .newlines) {
            // 이 파일의 주석은 항상 줄 단위이거나 값 뒤에 오지 않는다 — 단순 절단으로 충분하다.
            let line = String(rawLine.prefix(while: { $0 != "#" }))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }

            let indent = line.prefix(while: { $0 == " " }).count
            let key = String(trimmed[..<colon])
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            stack.append((indent, key))

            if !value.isEmpty {
                result[stack.map(\.key).joined(separator: ".")] = value
            }
        }
        return result
    }

    // MARK: - project.pbxproj

    /// 생성된 프로젝트의 `XCBuildConfiguration` 블록 — 구성 이름별 buildSettings 원문.
    ///
    /// 프로젝트 레벨과 타깃 레벨 블록이 모두 들어온다. 어떤 블록이 무엇인지 구분하는 대신
    /// "Release 블록 중 이 값을 끄는 것이 하나도 없다"처럼 **집합 전체**에 대해 단언한다 —
    /// 타깃 설정이 프로젝트 구성 값을 가리는 사고(같은 키를 타깃 base에 두는 실수)까지 잡힌다.
    static func buildConfigurationBlocks() throws -> [(name: String, settings: String)] {
        let text = try String(contentsOf: pbxprojURL, encoding: .utf8)
        var blocks: [(String, String)] = []

        for chunk in text.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst() {
            // 블록 끝은 `name = <구성>;` 이다. 다음 블록 내용까지 흘러들지 않도록 거기서 자른다.
            guard let nameRange = chunk.range(of: "name = ") else { continue }
            let afterName = chunk[nameRange.upperBound...]
            guard let semicolon = afterName.firstIndex(of: ";") else { continue }
            let name = afterName[..<semicolon].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            blocks.append((name, String(chunk[..<nameRange.lowerBound])))
        }
        return blocks
    }

    /// pbxproj 블록에서 `KEY = VALUE;`를 뽑는다(따옴표 제거).
    static func value(of key: String, in settings: String) -> String? {
        guard let range = settings.range(of: "\(key) = ") else { return nil }
        let rest = settings[range.upperBound...]
        guard let semicolon = rest.firstIndex(of: ";") else { return nil }
        return rest[..<semicolon].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }
}
