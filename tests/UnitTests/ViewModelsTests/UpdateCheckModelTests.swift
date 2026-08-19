import SwiftUI
import XCTest
@testable import UniFinder

/// 업데이트 확인 상태 기계 (후속 T3 / UI설계 §7.9).
///
/// 여기서 지키는 핵심 계약은 **"자동 확인은 절대 사용자를 방해하지 않는다"**이다:
/// 실패해도 조용하고, Skip한 버전은 다시 안 뜨고, 24시간에 한 번만 나간다.
@MainActor
final class UpdateCheckModelTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - 헬퍼

    private func makePreferences() -> UpdatePreferences {
        let suiteName = "UniFinderTests-Update-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("테스트 전용 UserDefaults suite 생성 실패")
            return UpdatePreferences()
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return UpdatePreferences(defaults: defaults)
    }

    private func releaseJSON(tag: String, body: String = "notes") -> String {
        """
        {"tag_name":"\(tag)","name":"UniFinder \(tag)","body":"\(body)","draft":false,"prerelease":false,
         "html_url":"https://github.com/acme/UniFinder/releases/tag/\(tag)"}
        """
    }

    private func makeModel(
        preferences: UpdatePreferences,
        current: String = "0.3.4",
        now: Date = Date(),
        opened: OpenedURLs = OpenedURLs(),
        stub: @escaping (URLRequest) -> StubURLProtocol.Stub
    ) -> UpdateCheckModel {
        let session = StubURLProtocol.makeSession(handler: stub)
        return UpdateCheckModel(
            preferences: preferences,
            checker: UpdateChecker(owner: "acme", repository: "UniFinder", session: session),
            currentVersion: SemanticVersion(current)!,
            opener: { url in opened.append(url); return true },
            now: { now }
        )
    }

    /// 브라우저 열기 기록 — 실제 브라우저는 절대 뜨지 않는다.
    final class OpenedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            urls.append(url)
        }
        var all: [URL] {
            lock.lock(); defer { lock.unlock() }
            return urls
        }
    }

    // MARK: - 새 버전 안내

    func testManualCheck_newerVersion_presentsAvailable() async {
        let preferences = makePreferences()
        let model = makeModel(preferences: preferences) { _ in .json(self.releaseJSON(tag: "v0.4.0")) }

        model.checkManually()
        await model.waitForCurrentCheck()

        guard case let .available(release, current) = model.presentation else {
            return XCTFail("새 버전 알림이 뜨지 않았다: \(String(describing: model.presentation))")
        }
        XCTAssertEqual(release.version, SemanticVersion("0.4.0"))
        XCTAssertEqual(current, SemanticVersion("0.3.4"))
        XCTAssertEqual(preferences.cachedLatestVersion, "0.4.0")
        XCTAssertNotNil(preferences.lastCheckedAt, "성공한 확인은 스로틀 시각을 갱신해야 한다")
    }

    /// **회귀 봉인** — 문자열 비교였다면 0.9.0이 0.10.0보다 크다고 판정해 알림이 뜨지 않는다.
    func testManualCheck_tenIsNewerThanNine() async {
        let model = makeModel(preferences: makePreferences(), current: "0.9.0") { _ in
            .json(self.releaseJSON(tag: "v0.10.0"))
        }

        model.checkManually()
        await model.waitForCurrentCheck()

        guard case let .available(release, _) = model.presentation else {
            return XCTFail("0.10.0 > 0.9.0 판정이 되지 않았다")
        }
        XCTAssertEqual(release.version, SemanticVersion("0.10.0"))
    }

    func testManualCheck_sameVersion_presentsUpToDate() async {
        let model = makeModel(preferences: makePreferences()) { _ in .json(self.releaseJSON(tag: "v0.3.4")) }

        model.checkManually()
        await model.waitForCurrentCheck()

        XCTAssertEqual(model.presentation, .upToDate(current: SemanticVersion("0.3.4")!))
    }

    func testAutomaticCheck_sameVersion_saysNothing() async {
        let preferences = makePreferences()
        let model = makeModel(preferences: preferences) { _ in .json(self.releaseJSON(tag: "v0.3.4")) }

        XCTAssertTrue(model.checkOnLaunchIfNeeded())
        await model.waitForCurrentCheck()

        XCTAssertNil(model.presentation, "최신 상태를 자동 확인이 알릴 이유가 없다")
    }

    // MARK: - 실패 처리 (D4의 핵심)

    /// **자동 확인 실패는 완전 침묵**. 이 단언이 깨지면 오프라인 사용자가 앱을 켤 때마다 알림을 본다.
    func testAutomaticCheck_failure_postsNoAlert() async {
        let preferences = makePreferences()
        let model = makeModel(preferences: preferences) { _ in .failure(.timedOut) }

        XCTAssertTrue(model.checkOnLaunchIfNeeded())
        await model.waitForCurrentCheck()

        XCTAssertNil(model.presentation, "자동 확인 실패가 알림을 띄웠다 — D4 위반")
        XCTAssertNil(preferences.lastCheckedAt, "실패가 스로틀 시각을 갱신하면 24시간 동안 자동 확인을 잃는다")
    }

    func testManualCheck_failure_presentsMessage() async {
        let model = makeModel(preferences: makePreferences()) { _ in .failure(.timedOut) }

        model.checkManually()
        await model.waitForCurrentCheck()

        XCTAssertEqual(model.presentation, .failed(message: UpdateCheckError.timedOut.message))
    }

    func testManualCheck_serverErrorsArePresented() async {
        for stub in [StubURLProtocol.Stub.json("{}", status: 404), .json("{}", status: 403), .json("{ broken", status: 200)] {
            let model = makeModel(preferences: makePreferences()) { _ in stub }
            model.checkManually()
            await model.waitForCurrentCheck()

            guard case .failed = model.presentation else {
                return XCTFail("수동 확인 실패가 보고되지 않았다: \(String(describing: model.presentation))")
            }
        }
    }

    // MARK: - Skip Version

    func testSkippedVersion_silencesAutomaticCheckOnly() async {
        let preferences = makePreferences()
        preferences.skip(SemanticVersion("0.4.0")!)

        let automatic = makeModel(preferences: preferences) { _ in .json(self.releaseJSON(tag: "v0.4.0")) }
        XCTAssertTrue(automatic.checkOnLaunchIfNeeded())
        await automatic.waitForCurrentCheck()
        XCTAssertNil(automatic.presentation, "Skip한 버전이 자동 확인에서 다시 떴다")

        let manual = makeModel(preferences: preferences) { _ in .json(self.releaseJSON(tag: "v0.4.0")) }
        manual.checkManually()
        await manual.waitForCurrentCheck()
        guard case .available = manual.presentation else {
            return XCTFail("수동 확인은 Skip을 무시하고 항상 결과를 보여야 한다")
        }
    }

    func testSkip_storesVersionAndDismisses() async {
        let preferences = makePreferences()
        let model = makeModel(preferences: preferences) { _ in .json(self.releaseJSON(tag: "v0.4.0")) }
        model.checkManually()
        await model.waitForCurrentCheck()

        guard case let .available(release, _) = model.presentation else { return XCTFail("사전 조건 실패") }
        model.skip(release)

        XCTAssertEqual(preferences.skippedVersion, "0.4.0")
        XCTAssertNil(model.presentation)
        // 표기가 달라도 같은 버전이면 침묵해야 한다.
        XCTAssertTrue(preferences.isSkipped(SemanticVersion("v0.4.0")!))
    }

    // MARK: - 스로틀

    func testAutomaticCheck_runsOncePerProcess() {
        let model = makeModel(preferences: makePreferences()) { _ in .json(self.releaseJSON(tag: "v0.4.0")) }

        XCTAssertTrue(model.checkOnLaunchIfNeeded())
        XCTAssertFalse(model.checkOnLaunchIfNeeded(), "창이 여러 개여도 시작 확인은 한 번만 나가야 한다")
    }

    func testAutomaticCheck_isThrottledFor24Hours() {
        let preferences = makePreferences()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        preferences.lastCheckedAt = now.addingTimeInterval(-60 * 60)

        let model = makeModel(preferences: preferences, now: now) { _ in .json(self.releaseJSON(tag: "v0.4.0")) }
        XCTAssertFalse(model.checkOnLaunchIfNeeded(), "1시간 전에 확인했으면 자동 확인은 나가지 않는다")

        preferences.lastCheckedAt = now.addingTimeInterval(-25 * 60 * 60)
        let later = makeModel(preferences: preferences, now: now) { _ in .json(self.releaseJSON(tag: "v0.4.0")) }
        XCTAssertTrue(later.checkOnLaunchIfNeeded(), "24시간이 지나면 다시 확인한다")
    }

    func testAutomaticCheck_disabledPreferenceStopsEverything() {
        let preferences = makePreferences()
        preferences.autoCheckEnabled = false

        let model = makeModel(preferences: preferences) { _ in .json(self.releaseJSON(tag: "v0.4.0")) }

        XCTAssertFalse(model.checkOnLaunchIfNeeded(), "끌 수 있어야 설계서 §1.2 예외 경계 (d)가 성립한다")
    }

    func testManualCheck_ignoresThrottle() async {
        let preferences = makePreferences()
        let now = Date()
        preferences.lastCheckedAt = now
        let model = makeModel(preferences: preferences, now: now) { _ in .json(self.releaseJSON(tag: "v0.4.0")) }

        model.checkManually()
        await model.waitForCurrentCheck()

        guard case .available = model.presentation else {
            return XCTFail("수동 확인이 스로틀에 막혔다")
        }
    }

    // MARK: - 304 캐시

    func testNotModified_usesCachedVersion() async {
        let preferences = makePreferences()
        preferences.cachedETag = "\"etag-1\""
        preferences.cachedLatestVersion = "0.4.0"

        let model = makeModel(preferences: preferences) { _ in .success(status: 304, body: Data(), headers: [:]) }
        model.checkManually()
        await model.waitForCurrentCheck()

        guard case let .available(release, _) = model.presentation else {
            return XCTFail("304 응답에서 캐시된 버전을 쓰지 못했다: \(String(describing: model.presentation))")
        }
        XCTAssertEqual(release.version, SemanticVersion("0.4.0"))
        XCTAssertFalse(release.pageURL.absoluteString.isEmpty, "노트가 없어도 링크는 있어야 한다")
    }

    func testNotModified_withCachedSameVersion_manualSaysUpToDate() async {
        let preferences = makePreferences()
        preferences.cachedETag = "\"etag-1\""
        preferences.cachedLatestVersion = "0.3.4"

        let model = makeModel(preferences: preferences) { _ in .success(status: 304, body: Data(), headers: [:]) }
        model.checkManually()
        await model.waitForCurrentCheck()

        XCTAssertEqual(model.presentation, .upToDate(current: SemanticVersion("0.3.4")!))
    }

    // MARK: - 다운로드는 브라우저 위임

    func testDownload_opensReleasePageAndDoesNotFetchBinary() async {
        let opened = OpenedURLs()
        let model = makeModel(preferences: makePreferences(), opened: opened) { _ in
            .json(self.releaseJSON(tag: "v0.4.0"))
        }
        model.checkManually()
        await model.waitForCurrentCheck()

        guard case let .available(release, _) = model.presentation else { return XCTFail("사전 조건 실패") }
        XCTAssertTrue(model.download(release))

        XCTAssertEqual(
            opened.all.map(\.absoluteString),
            ["https://github.com/acme/UniFinder/releases/tag/v0.4.0"],
            "앱이 직접 내려받으면 설계서 §1.2 예외 경계 (b)를 넘는다 — 브라우저에 위임해야 한다"
        )
        XCTAssertNil(model.presentation)
    }

    // MARK: - 알림 문구

    func testAlertText_matchesSpec() {
        let release = UpdateRelease(
            version: SemanticVersion("0.4.0")!,
            tagName: "v0.4.0",
            title: "UniFinder 0.4.0",
            notes: "- Get Info window\n- Open With submenu",
            pageURL: URL(string: "https://example.com")!
        )
        let presentation = UpdateCheckModel.Presentation.available(release, current: SemanticVersion("0.3.4")!)

        XCTAssertEqual(UpdateCheckAlertModifier.title(for: presentation), "UniFinder 0.4.0 is available.")
        let message = UpdateCheckAlertModifier.message(for: presentation)
        XCTAssertTrue(message.contains("You have 0.3.4."))
        XCTAssertTrue(message.contains("What's New"))
        XCTAssertTrue(message.contains("- Get Info window"), "릴리스 노트는 원문 그대로 실린다")

        XCTAssertEqual(
            UpdateCheckAlertModifier.title(for: .upToDate(current: SemanticVersion("0.3.4")!)),
            "You're up to date."
        )
        XCTAssertEqual(UpdateCheckAlertModifier.title(for: .failed(message: "x")), "Couldn't check for updates.")
    }

    func testAlertText_truncatesVeryLongNotes() {
        let long = String(repeating: "a", count: UpdateCheckAlertModifier.maximumNotesLength + 500)

        let truncated = UpdateCheckAlertModifier.truncatedNotes(long)

        XCTAssertEqual(truncated.count, UpdateCheckAlertModifier.maximumNotesLength + 1)
        XCTAssertTrue(truncated.hasSuffix("…"))
    }

    // MARK: - 저장소

    func testPreferences_defaultsAndPersistence() {
        let suiteName = "UniFinderTests-UpdatePrefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let first = UpdatePreferences(defaults: defaults)
        XCTAssertTrue(first.autoCheckEnabled, "키 부재는 '켬'이어야 한다(최초 실행)")
        first.autoCheckEnabled = false
        first.skippedVersion = "0.4.0"
        first.cachedETag = "\"e\""

        let second = UpdatePreferences(defaults: defaults)
        XCTAssertFalse(second.autoCheckEnabled)
        XCTAssertEqual(second.skippedVersion, "0.4.0")
        XCTAssertEqual(second.cachedETag, "\"e\"")
    }

    /// 별도 suite를 만들지 않고 `update.` 접두사만 쓴다(D10) — 키 이름을 회귀로 고정한다.
    func testPreferences_keysUseUpdatePrefix() {
        let suiteName = "UniFinderTests-UpdateKeys-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = UpdatePreferences(defaults: defaults)
        preferences.autoCheckEnabled = false
        preferences.skippedVersion = "1.0.0"
        preferences.cachedETag = "\"e\""
        preferences.cachedLatestVersion = "1.0.0"
        preferences.lastCheckedAt = Date()

        let stored = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("update.") }
        XCTAssertEqual(
            Set(stored),
            ["update.autoCheckEnabled", "update.skippedVersion", "update.cachedETag",
             "update.cachedLatestVersion", "update.lastCheckedAt"]
        )
    }

    /// 시계가 뒤로 간 경우(시간대 변경·수동 조정)에도 자동 확인이 영구히 막히지 않아야 한다.
    func testPreferences_backwardsClockDoesNotBlockChecks() {
        let preferences = makePreferences()
        let now = Date()
        preferences.lastCheckedAt = now.addingTimeInterval(60 * 60 * 24 * 30)

        XCTAssertTrue(preferences.shouldAutoCheck(now: now))
    }

    // MARK: - 자동 확인 토글 (설계서 §1.2 경계 (d) / reviewer major #3)

    /// Help 메뉴 토글이 실제로 `UpdatePreferences`를 뒤집어야 한다 —
    /// 중간에 로컬 상태를 두면 "껐는데 다음 실행에서 다시 켜져 있다"가 된다.
    func testAutomaticUpdateCheckToggle_bindingReflectsPreferences() {
        let preferences = makePreferences()
        let binding = AutomaticUpdateCheckToggle.binding(for: preferences)

        XCTAssertTrue(binding.wrappedValue, "최초 실행은 켬이다")

        binding.wrappedValue = false
        XCTAssertFalse(preferences.autoCheckEnabled, "토글이 저장소를 바꾸지 않았다")
        XCTAssertFalse(binding.wrappedValue, "저장소 값을 다시 읽어야 한다")

        binding.wrappedValue = true
        XCTAssertTrue(preferences.autoCheckEnabled)
    }

    /// 저장소를 직접 바꿔도 토글이 그 값을 읽어야 한다(단방향 캐시가 아니다).
    func testAutomaticUpdateCheckToggle_bindingReadsBackExternalChange() {
        let preferences = makePreferences()
        let binding = AutomaticUpdateCheckToggle.binding(for: preferences)

        preferences.autoCheckEnabled = false

        XCTAssertFalse(binding.wrappedValue)
    }

    /// **핵심 계약**: 토글을 끄면 자동 확인이 실제로 나가지 않아야 한다.
    /// 설계서 §1.2가 네트워크 예외를 승인한 조건 (d)가 바로 이것이다.
    func testAutomaticUpdateCheckToggle_offSuppressesLaunchCheck() async {
        let preferences = makePreferences()
        let model = makeModel(preferences: preferences) { _ in .json(self.releaseJSON(tag: "v9.9.9")) }
        AutomaticUpdateCheckToggle.binding(for: preferences).wrappedValue = false

        let started = model.checkOnLaunchIfNeeded()
        await model.waitForCurrentCheck()

        XCTAssertFalse(started, "자동 확인을 껐는데도 시작 확인이 나갔다 — 네트워크 예외 조건 (d) 위반")
        XCTAssertNil(model.presentation)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty, "요청이 한 건도 나가면 안 된다")
    }

    /// 껐다 켜면 다시 나간다(토글이 편도가 아니다).
    func testAutomaticUpdateCheckToggle_onRestoresLaunchCheck() async {
        let preferences = makePreferences()
        let model = makeModel(preferences: preferences) { _ in .json(self.releaseJSON(tag: "v9.9.9")) }
        let binding = AutomaticUpdateCheckToggle.binding(for: preferences)
        binding.wrappedValue = false
        binding.wrappedValue = true

        let started = model.checkOnLaunchIfNeeded()
        await model.waitForCurrentCheck()

        XCTAssertTrue(started)
    }

    /// 토글 항목이 Help 메뉴에 실제로 걸려 있는지 (SwiftUI `Commands`는 렌더링 단언이 불가능하다).
    func testAutomaticUpdateCheckToggle_isWiredIntoHelpMenu() throws {
        let source = try String(
            contentsOf: ProjectManifest.repositoryRoot.appendingPathComponent("src/App/AppCommands.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("AutomaticUpdateCheckToggle()"),
            "자동 확인을 끌 수 있는 UI가 메뉴에 없다 — 설계서 §1.2 경계 (d)를 만족하지 못한다"
        )
        XCTAssertTrue(source.contains("Automatically Check for Updates"))
    }
}
