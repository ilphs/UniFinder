import XCTest
@testable import UniFinder

/// 수동 확인 **진행 표시** (reviewer minor #10).
///
/// 확인은 timeout까지 최대 10초가 걸린다. 그동안 Help 메뉴 항목이 평소와 똑같아 보이면
/// 사용자는 눌리지 않은 줄 알고 다시 누르고, 그때마다 이전 확인이 취소되고 새 요청이 나간다.
/// `isChecking`은 예전에 아무도 읽지 않는 값이었다 — 메뉴가 그것을 읽게 만든 뒤로는
/// **시작에서 참, 끝나는 모든 경로에서 거짓**이라는 계약이 화면에 그대로 드러난다.
@MainActor
final class UpdateCheckProgressTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makePreferences() -> UpdatePreferences {
        let suiteName = "UniFinderTests-UpdateProgress-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("테스트 전용 UserDefaults suite 생성 실패")
            return UpdatePreferences()
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return UpdatePreferences(defaults: defaults)
    }

    private func makeModel(stub: @escaping (URLRequest) -> StubURLProtocol.Stub) -> UpdateCheckModel {
        UpdateCheckModel(
            preferences: makePreferences(),
            checker: UpdateChecker(
                owner: "acme",
                repository: "UniFinder",
                session: StubURLProtocol.makeSession(handler: stub)
            ),
            currentVersion: SemanticVersion("0.3.4")!,
            opener: { _ in true },
            now: { Date() }
        )
    }

    private func releaseJSON(tag: String) -> String {
        """
        {"tag_name":"\(tag)","name":"UniFinder \(tag)","body":"notes","draft":false,"prerelease":false,
         "html_url":"https://github.com/acme/UniFinder/releases/tag/\(tag)"}
        """
    }

    // MARK: - 상태 기계

    func testIsChecking_isTrueWhileRunningAndFalseAfterSuccess() async {
        let model = makeModel { _ in .json(self.releaseJSON(tag: "v0.4.0")) }

        XCTAssertFalse(model.isChecking, "시작 전에는 진행 중이 아니다")
        model.checkManually()
        XCTAssertTrue(model.isChecking, "메뉴가 '확인 중'을 표시할 근거가 없다")

        await model.waitForCurrentCheck()
        XCTAssertFalse(model.isChecking, "끝났는데 메뉴가 계속 '확인 중'으로 남는다")
    }

    func testIsChecking_isClearedAfterFailure() async {
        let model = makeModel { _ in .failure(.timedOut) }

        model.checkManually()
        await model.waitForCurrentCheck()

        XCTAssertFalse(model.isChecking, "실패도 끝난 것이다 — 표시가 남으면 메뉴가 영영 비활성이 된다")
        XCTAssertNotNil(model.presentation, "수동 확인은 실패도 반드시 말한다(D4)")
    }

    /// **연속 호출 회귀**: 이전 확인이 취소되며 지나가는 정리 코드가 방금 시작한 확인의
    /// 진행 표시를 꺼 버리면, 메뉴는 "끝났다"고 말하는데 요청은 아직 돌고 있는 상태가 된다.
    func testIsChecking_survivesCancellationOfAnEarlierCheck() async {
        let model = makeModel { _ in .json(self.releaseJSON(tag: "v0.4.0")) }

        model.checkManually()
        model.checkManually()
        XCTAssertTrue(model.isChecking, "두 번째 확인이 도는 중인데 표시가 꺼졌다")

        await model.waitForCurrentCheck()
        XCTAssertFalse(model.isChecking)
    }

    // MARK: - 메뉴 문구 (Help > Check for Updates…)

    func testMenuTitle_saysCheckingWhileInFlight() {
        XCTAssertEqual(CheckForUpdatesButton.title(isChecking: false), "Check for Updates…")
        XCTAssertEqual(
            CheckForUpdatesButton.title(isChecking: true), "Checking for Updates…",
            "진행 중임을 말하지 않으면 사용자는 최대 10초를 무반응으로 오해한다"
        )
    }

    func testMenuItem_isDisabledWhileCheckingOrWithoutAWindow() {
        XCTAssertFalse(CheckForUpdatesButton.isDisabled(isChecking: false, canPresentGlobalAlert: true))
        XCTAssertTrue(
            CheckForUpdatesButton.isDisabled(isChecking: true, canPresentGlobalAlert: true),
            "확인 중에 다시 누르면 진행 중인 확인이 취소되고 요청만 늘어난다"
        )
        // reviewer major #2의 계약은 그대로 남는다 — 창이 없으면 결과를 띄울 곳이 없다.
        XCTAssertTrue(CheckForUpdatesButton.isDisabled(isChecking: false, canPresentGlobalAlert: false))
    }

    /// `latestKnownVersion`은 제거됐다 — 같은 사실을 `cachedLatestVersion`이 들고 있고,
    /// 그쪽은 304 판정에 실제로 쓰이며 실행 사이에도 남는다(사본을 둘 이유가 없다).
    func testLatestVersionIsRememberedInPreferencesOnly() async {
        let preferences = makePreferences()
        let model = UpdateCheckModel(
            preferences: preferences,
            checker: UpdateChecker(
                owner: "acme",
                repository: "UniFinder",
                session: StubURLProtocol.makeSession { _ in .json(self.releaseJSON(tag: "v0.4.0")) }
            ),
            currentVersion: SemanticVersion("0.3.4")!,
            opener: { _ in true },
            now: { Date() }
        )

        model.checkManually()
        await model.waitForCurrentCheck()

        XCTAssertEqual(preferences.cachedLatestVersion, "0.4.0")
    }
}
