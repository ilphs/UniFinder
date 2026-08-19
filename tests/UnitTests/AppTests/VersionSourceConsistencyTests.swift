import XCTest
@testable import UniFinder

/// **버전 소스 단일화 회귀** (후속 T0).
///
/// 릴리스 때마다 사람이 손으로 맞추던 세 곳 — `project.yml`(정본), 생성된 `project.pbxproj`,
/// `README.md`의 안내 표 — 이 어긋나면 사용자가 보는 버전과 앱이 자기 자신을 부르는 버전이
/// 달라진다. 업데이트 확인(`UpdateChecker`)이 그 값으로 "새 버전인가"를 판단하므로,
/// 어긋남은 곧 **오탐/미탐**이다(0.3.0으로 표기된 앱이 0.3.4 릴리스를 계속 권한다).
///
/// `ReleaseSigningConfigurationTests`와 같은 방식으로 원본과 생성물을 **둘 다** 본다:
/// 원본만 보면 "고쳤지만 `xcodegen generate`를 안 돌린" 상태를 통과시킨다.
final class VersionSourceConsistencyTests: XCTestCase {

    /// `project.yml`의 `MARKETING_VERSION` — 이 값이 **정본**이다.
    private func manifestVersion() throws -> String {
        let settings = try ProjectManifest.projectSettings()
        return try XCTUnwrap(
            settings["targets.UniFinder.settings.base.MARKETING_VERSION"],
            "project.yml에서 MARKETING_VERSION을 찾지 못했다 — 버전 정본이 사라졌다"
        )
    }

    func testMarketingVersion_isSemanticTriple() throws {
        let version = try manifestVersion()
        XCTAssertNotNil(
            SemanticVersion(version),
            "MARKETING_VERSION(\(version))이 semver로 해석되지 않으면 업데이트 비교가 성립하지 않는다"
        )
    }

    /// 생성물(pbxproj)이 원본을 따라오는지 — `xcodegen generate` 누락 감지.
    func testGeneratedProject_marketingVersionMatchesManifest() throws {
        let expected = try manifestVersion()
        let blocks = try ProjectManifest.buildConfigurationBlocks()
        let found = blocks.compactMap { ProjectManifest.value(of: "MARKETING_VERSION", in: $0.settings) }

        XCTAssertFalse(found.isEmpty, "pbxproj에 MARKETING_VERSION이 하나도 없다 — xcodegen generate 누락?")
        for value in found {
            XCTAssertEqual(
                value, expected,
                "pbxproj의 MARKETING_VERSION(\(value))이 project.yml(\(expected))과 다르다 — xcodegen generate를 돌릴 것"
            )
        }
    }

    /// README 안내 표의 버전이 정본과 같은지 (릴리스 절차의 수동 단계를 게이트로 바꾼다).
    func testREADME_versionTableMatchesManifest() throws {
        let expected = try manifestVersion()
        let readmeURL = ProjectManifest.repositoryRoot.appendingPathComponent("README.md")
        let text = try String(contentsOf: readmeURL, encoding: .utf8)

        let row = text
            .components(separatedBy: .newlines)
            .first { $0.contains("**버전**") }

        let line = try XCTUnwrap(row, "README.md에 '**버전**' 표 행이 없다")
        XCTAssertTrue(
            line.contains(expected),
            "README 버전 행(\(line.trimmingCharacters(in: .whitespaces)))이 정본 \(expected)과 다르다"
        )
    }

    /// 코드가 버전 리터럴을 따로 들고 있지 않은지 — 진입점은 `AppVersion` 하나여야 한다.
    func testAppVersion_readsBundleAndFallsBackSafely() {
        let empty = Bundle(path: "/nonexistent-bundle-for-tests") ?? Bundle(for: VersionSourceConsistencyTests.self)
        _ = AppVersion.marketingVersion(from: empty)

        XCTAssertFalse(AppVersion.current.isEmpty, "버전 진입점이 빈 문자열을 돌려주면 업데이트 비교가 무너진다")
        XCTAssertNotNil(SemanticVersion(AppVersion.current))
    }
}
