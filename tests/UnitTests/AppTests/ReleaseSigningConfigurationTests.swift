import XCTest
@testable import UniFinder

/// 릴리스 서명/hardened runtime 구성 회귀 테스트 (M3 리뷰 — 릴리스 차단 2).
///
/// **문제**: 개발 편의를 위한 ad-hoc 서명(`CODE_SIGN_IDENTITY = "-"`, hardened runtime 끔)이
/// 전 구성에 걸려 있으면, 릴리스 빌드도 그대로 나간다. 이건 "사람이 릴리스 직전에 기억해서
/// 켜는" 절차이고, 절차는 반드시 잊힌다. 그래서 구성 분리를 **자동 게이트**로 고정한다.
///
/// - Debug: ad-hoc 유지 — 개발 중 재빌드마다 TCC(전체 디스크 접근) 승인이 리셋되는 것을
///   피하려는 의도적 선택이다 (m3-impl B21 방침 (b), 테스트계획 §4.3 전제).
/// - Release: Developer ID Application + hardened runtime + `--timestamp`.
///
/// 서명만으로는 Gatekeeper를 통과하지 못한다 — 공증(`notarytool`) + `stapler`가 이어져야 하며
/// 절차는 `ref-docs/specs/impl/unifinder-m3-impl.md` 릴리스 절차 절에 있다.
final class ReleaseSigningConfigurationTests: XCTestCase {

    // MARK: - project.yml (원본)

    func testProjectYAML_releaseConfigEnablesHardenedRuntimeAndDeveloperIDSigning() throws {
        let settings = try ProjectManifest.projectSettings()

        XCTAssertEqual(
            settings["settings.configs.Release.ENABLE_HARDENED_RUNTIME"], "YES",
            "Release 구성에 hardened runtime이 꺼져 있다 — 공증(notarization)이 거부된다"
        )
        XCTAssertEqual(
            settings["settings.configs.Release.CODE_SIGN_IDENTITY"], "Developer ID Application",
            "Release 구성이 Developer ID로 서명되지 않는다 — 배포본이 Gatekeeper에 막힌다"
        )
        XCTAssertEqual(
            settings["settings.configs.Release.OTHER_CODE_SIGN_FLAGS"], "--timestamp",
            "Release 서명에 secure timestamp가 없다 — 공증 요구사항 미충족"
        )
    }

    func testProjectYAML_debugConfigStaysAdHocForFullDiskAccessTesting() throws {
        let settings = try ProjectManifest.projectSettings()

        XCTAssertEqual(
            settings["settings.configs.Debug.CODE_SIGN_IDENTITY"], "-",
            "Debug가 ad-hoc 서명이 아니다 — 매 빌드 FDA 승인이 리셋돼 수동 시나리오(§4.3)를 검증할 수 없다"
        )
        XCTAssertEqual(
            settings["settings.configs.Debug.ENABLE_HARDENED_RUNTIME"], "NO",
            "Debug에 hardened runtime이 켜졌다 — 개발 중 디버거/주입 경로가 막힌다"
        )
    }

    /// 타깃 base에 같은 키를 두면 **구성별 값이 통째로 가려진다**. 예전 `project.yml`이 앱 타깃
    /// base에 `ENABLE_HARDENED_RUNTIME: NO`를 두고 있었고, 그 상태로 프로젝트 Release 구성만
    /// 고치면 아무 효과가 없다. 그 재발을 막는다.
    func testProjectYAML_targetsDoNotShadowConfigurationLevelSigningKeys() throws {
        let settings = try ProjectManifest.projectSettings()
        let shadowingKeys = settings.keys.filter { key in
            key.hasPrefix("targets.")
                && (key.hasSuffix(".ENABLE_HARDENED_RUNTIME")
                    || key.hasSuffix(".CODE_SIGN_IDENTITY")
                    || key.hasSuffix(".OTHER_CODE_SIGN_FLAGS"))
        }

        XCTAssertTrue(
            shadowingKeys.isEmpty,
            "타깃 설정이 구성별 서명 설정을 가린다: \(shadowingKeys.sorted())"
        )

        XCTAssertNil(
            settings["settings.base.CODE_SIGN_IDENTITY"],
            "settings.base에 CODE_SIGN_IDENTITY가 남아 있다 — 구성 분리의 의미가 흐려진다"
        )
        XCTAssertNil(
            settings["settings.base.ENABLE_HARDENED_RUNTIME"],
            "settings.base에 ENABLE_HARDENED_RUNTIME이 남아 있다 — 구성 분리의 의미가 흐려진다"
        )
    }

    // MARK: - project.pbxproj (xcodebuild가 실제로 읽는 생성물)

    func testGeneratedProject_releaseConfigurationsCarrySigningHardening() throws {
        let blocks = try ProjectManifest.buildConfigurationBlocks()
        XCTAssertFalse(blocks.isEmpty, "생성된 프로젝트에서 빌드 구성을 읽지 못했다 — xcodegen generate 필요")

        let release = blocks.filter { $0.name == "Release" }
        XCTAssertFalse(release.isEmpty, "Release 빌드 구성이 없다")

        let hardened = release.compactMap { ProjectManifest.value(of: "ENABLE_HARDENED_RUNTIME", in: $0.settings) }
        XCTAssertTrue(
            hardened.contains("YES"),
            "생성된 프로젝트의 Release 구성에 ENABLE_HARDENED_RUNTIME=YES가 없다 — project.yml 수정 후 xcodegen generate를 돌리지 않았을 수 있다"
        )
        XCTAssertFalse(
            hardened.contains("NO"),
            "Release 구성 어딘가가 hardened runtime을 다시 끄고 있다(타깃 오버라이드 의심)"
        )

        let identities = release.compactMap { ProjectManifest.value(of: "CODE_SIGN_IDENTITY", in: $0.settings) }
        XCTAssertTrue(
            identities.contains("Developer ID Application"),
            "Release 구성에 Developer ID Application 서명이 없다"
        )
        XCTAssertFalse(
            identities.contains("-"),
            "Release 구성이 ad-hoc 서명(\"-\")으로 남아 있다"
        )

        let flags = release.compactMap { ProjectManifest.value(of: "OTHER_CODE_SIGN_FLAGS", in: $0.settings) }
        XCTAssertTrue(
            flags.contains(where: { $0.contains("--timestamp") }),
            "Release 서명 플래그에 --timestamp가 없다"
        )
    }

    func testGeneratedProject_debugConfigurationsStayAdHoc() throws {
        let blocks = try ProjectManifest.buildConfigurationBlocks()
        let debug = blocks.filter { $0.name == "Debug" }
        XCTAssertFalse(debug.isEmpty, "Debug 빌드 구성이 없다")

        let hardened = debug.compactMap { ProjectManifest.value(of: "ENABLE_HARDENED_RUNTIME", in: $0.settings) }
        XCTAssertFalse(
            hardened.contains("YES"),
            "Debug 구성에 hardened runtime이 켜졌다 — 개발 빌드 전제(B21)가 깨진다"
        )

        let identities = debug.compactMap { ProjectManifest.value(of: "CODE_SIGN_IDENTITY", in: $0.settings) }
        XCTAssertFalse(
            identities.contains("Developer ID Application"),
            "Debug가 Developer ID로 서명된다 — 매 빌드 FDA 승인이 리셋된다"
        )
    }
}
