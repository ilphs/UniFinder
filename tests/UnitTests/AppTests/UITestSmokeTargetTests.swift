import XCTest
@testable import UniFinder

/// XCUITest 스모크 타깃 존재 회귀 테스트 (테스트계획 §4.4 / M3 리뷰 — 릴리스 차단 1).
///
/// 테스트계획은 스모크 1본을 규정하고 있었지만 **UITest 타깃 자체가 `project.yml`에 없었고**,
/// 그래서 "앱이 한 번도 실행되지 않은 채" 단위 테스트만으로 릴리스 판정을 받으려는 상태가 됐다.
/// 타깃/스킴 등록이 조용히 사라지면 스모크는 실행되지 않으면서 초록불만 남는다 — 그 상태를 막는다.
final class UITestSmokeTargetTests: XCTestCase {

    func testProjectYAML_declaresUITestTargetBoundToApp() throws {
        let settings = try ProjectManifest.projectSettings()

        XCTAssertEqual(
            settings["targets.UniFinderUITests.type"], "bundle.ui-testing",
            "UITest 타깃(UniFinderUITests)이 없거나 타입이 다르다 — 스모크가 빌드조차 되지 않는다"
        )
        XCTAssertEqual(
            settings["targets.UniFinderUITests.settings.base.TEST_TARGET_NAME"], "UniFinder",
            "UITest 타깃이 앱 타깃에 연결되지 않았다"
        )
    }

    func testGeneratedProject_containsUITestTargetAndSmokeSource() throws {
        let pbxproj = try String(contentsOf: ProjectManifest.pbxprojURL, encoding: .utf8)

        XCTAssertTrue(
            pbxproj.contains("com.apple.product-type.bundle.ui-testing"),
            "생성된 프로젝트에 UI 테스트 번들 타깃이 없다 — xcodegen generate 필요"
        )
        XCTAssertTrue(
            pbxproj.contains("NavigationSmokeUITests.swift"),
            "스모크 소스가 UITest 타깃에 포함되지 않았다"
        )

        let smokeSource = ProjectManifest.repositoryRoot
            .appendingPathComponent("tests/UITests/NavigationSmokeUITests.swift")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: smokeSource.path),
            "스모크 테스트 파일이 사라졌다: \(smokeSource.path)"
        )
    }

    /// 스킴의 test 액션에 UITest 타깃이 들어 있어야 `xcodebuild -scheme UniFinder test`가 스모크를 돌린다.
    func testScheme_runsUITestTargetInTestAction() throws {
        let scheme = ProjectManifest.repositoryRoot
            .appendingPathComponent("UniFinder.xcodeproj/xcshareddata/xcschemes/UniFinder.xcscheme")
        let text = try String(contentsOf: scheme, encoding: .utf8)

        XCTAssertTrue(
            text.contains("UniFinderUITests"),
            "스킴 test 액션에 UITest 타깃이 없다 — 스모크가 게이트에서 실행되지 않는다"
        )
        XCTAssertTrue(
            text.contains("UnitTests"),
            "스킴 test 액션에 단위 테스트 타깃이 없다"
        )
    }
}
