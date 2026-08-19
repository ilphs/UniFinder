import XCTest
@testable import UniFinder

/// semver 파싱·비교 (후속 T3 / D4).
///
/// 이 타입이 존재하는 이유는 단 하나다: **문자열 비교를 쓰면 `"0.10.0" < "0.9.0"`이 참**이라
/// 0.9.0 사용자가 0.10.0 릴리스를 영영 안내받지 못한다. 그 결함을 여기서 봉인한다.
final class SemanticVersionTests: XCTestCase {

    // MARK: - 파싱

    func testParse_plainTriple() {
        let version = SemanticVersion("1.2.3")
        XCTAssertEqual(version?.major, 1)
        XCTAssertEqual(version?.minor, 2)
        XCTAssertEqual(version?.patch, 3)
        XCTAssertEqual(version?.prerelease, [])
    }

    /// GitHub 태그 관례 — `v` 접두는 버전의 일부가 아니다.
    func testParse_stripsVPrefix() {
        XCTAssertEqual(SemanticVersion("v0.3.4"), SemanticVersion(major: 0, minor: 3, patch: 4))
        XCTAssertEqual(SemanticVersion("V0.3.4"), SemanticVersion(major: 0, minor: 3, patch: 4))
    }

    func testParse_missingComponentsDefaultToZero() {
        XCTAssertEqual(SemanticVersion("2"), SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(SemanticVersion("2.1"), SemanticVersion(major: 2, minor: 1, patch: 0))
    }

    func testParse_prereleaseAndBuildMetadata() {
        let version = SemanticVersion("1.0.0-beta.2+build.77")
        XCTAssertEqual(version?.prerelease, ["beta", "2"])
        XCTAssertEqual(version?.patch, 0)
        XCTAssertEqual(version?.isPrerelease, true)
    }

    func testParse_rejectsUnparseableInput() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("latest"))
        XCTAssertNil(SemanticVersion("1.2.3.4"), "네 자리는 semver가 아니다")
        XCTAssertNil(SemanticVersion("1..3"))
        XCTAssertNil(SemanticVersion("1.2.x"))
        XCTAssertNil(SemanticVersion("-1.0.0"))
    }

    func testParse_trimsWhitespace() {
        XCTAssertEqual(SemanticVersion("  v1.0.0\n"), SemanticVersion(major: 1, minor: 0, patch: 0))
    }

    // MARK: - 비교 (이 파일의 존재 이유)

    /// **회귀 봉인** — 문자열 비교로 되돌리면 이 단언이 즉시 깨진다.
    func testCompare_tenIsGreaterThanNine() {
        XCTAssertTrue(
            SemanticVersion("0.10.0")! > SemanticVersion("0.9.0")!,
            "문자열 비교로 되돌아갔다 — 0.9.0 사용자가 0.10.0을 영영 안내받지 못한다"
        )
        XCTAssertTrue(SemanticVersion("1.0.10")! > SemanticVersion("1.0.9")!)
        XCTAssertTrue(SemanticVersion("10.0.0")! > SemanticVersion("9.99.99")!)
    }

    func testCompare_ordersByMajorThenMinorThenPatch() {
        XCTAssertTrue(SemanticVersion("2.0.0")! > SemanticVersion("1.99.99")!)
        XCTAssertTrue(SemanticVersion("1.2.0")! > SemanticVersion("1.1.99")!)
        XCTAssertTrue(SemanticVersion("1.1.2")! > SemanticVersion("1.1.1")!)
        XCTAssertEqual(SemanticVersion("1.1.1")!, SemanticVersion("v1.1.1")!)
    }

    /// semver §11.3 — 프리릴리스가 붙은 쪽이 **낮다**. 0.4.0-beta에 0.4.0을 권해야 한다.
    func testCompare_prereleaseIsLowerThanRelease() {
        XCTAssertTrue(SemanticVersion("1.0.0-beta")! < SemanticVersion("1.0.0")!)
        XCTAssertFalse(SemanticVersion("1.0.0")! < SemanticVersion("1.0.0-beta")!)
    }

    func testCompare_prereleaseIdentifierOrdering() {
        XCTAssertTrue(SemanticVersion("1.0.0-alpha")! < SemanticVersion("1.0.0-beta")!)
        XCTAssertTrue(SemanticVersion("1.0.0-beta.2")! < SemanticVersion("1.0.0-beta.10")!, "숫자 식별자는 수치로 비교한다")
        XCTAssertTrue(SemanticVersion("1.0.0-1")! < SemanticVersion("1.0.0-alpha")!, "숫자 식별자는 비숫자보다 낮다")
        XCTAssertTrue(SemanticVersion("1.0.0-beta")! < SemanticVersion("1.0.0-beta.1")!, "앞이 같으면 식별자가 적은 쪽이 낮다")
    }

    /// 빌드 메타데이터는 비교에 관여하지 않는다(semver §10).
    func testCompare_ignoresBuildMetadata() {
        XCTAssertEqual(SemanticVersion("1.0.0+a")!, SemanticVersion("1.0.0+b")!)
        XCTAssertFalse(SemanticVersion("1.0.0+a")! < SemanticVersion("1.0.0+b")!)
    }

    func testDescription_roundTrips() {
        XCTAssertEqual(SemanticVersion("v1.2.3")!.description, "1.2.3")
        XCTAssertEqual(SemanticVersion("1.2.3-rc.1+meta")!.description, "1.2.3-rc.1")
        XCTAssertEqual(SemanticVersion(SemanticVersion("2.0")!.description), SemanticVersion("2.0.0")!)
    }
}
