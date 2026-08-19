import XCTest
@testable import UniFinder

/// GitHub Releases 조회 (후속 T3 / D4).
///
/// **실제 네트워크를 절대 타지 않는다** — `StubURLProtocol`로 응답을 지어낸다.
/// 여기서 지키는 계약은 "어떤 응답이 와도 앱이 안전하게 계속 돈다"이다.
final class UpdateCheckerTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeChecker(_ handler: @escaping (URLRequest) -> StubURLProtocol.Stub) -> UpdateChecker {
        UpdateChecker(owner: "acme", repository: "UniFinder", session: StubURLProtocol.makeSession(handler: handler))
    }

    private func releaseJSON(
        tag: String = "v0.4.0",
        name: String = "UniFinder 0.4.0",
        body: String = "- Get Info window",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> String {
        """
        {
          "tag_name": "\(tag)",
          "name": "\(name)",
          "body": "\(body)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "html_url": "https://github.com/acme/UniFinder/releases/tag/\(tag)"
        }
        """
    }

    // MARK: - 정상 경로

    func testFetch_parsesLatestRelease() async throws {
        let checker = makeChecker { _ in .json(self.releaseJSON()) }

        let result = try await checker.fetchLatestRelease()

        guard case let .release(release) = result.response else {
            return XCTFail("릴리스를 읽지 못했다: \(result.response)")
        }
        XCTAssertEqual(release.version, SemanticVersion("0.4.0"))
        XCTAssertEqual(release.tagName, "v0.4.0")
        XCTAssertEqual(release.title, "UniFinder 0.4.0")
        XCTAssertEqual(release.notes, "- Get Info window")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/acme/UniFinder/releases/tag/v0.4.0")
    }

    /// 요청 자체의 계약 — GET, 인증 헤더 없음(설계서 §1.2 예외 경계 (a)(c)).
    func testFetch_sendsReadOnlyUnauthenticatedGET() async throws {
        let checker = makeChecker { _ in .json(self.releaseJSON()) }
        _ = try await checker.fetchLatestRelease()

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "인증 헤더를 붙이면 예외 경계 (c)를 넘는다")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/acme/UniFinder/releases/latest")
        XCTAssertEqual(request.timeoutInterval, UpdateChecker.requestTimeout)
    }

    func testFetch_capturesETagAndSendsIfNoneMatchOnNextCall() async throws {
        let checker = makeChecker { _ in .json(self.releaseJSON(), headers: ["ETag": "\"etag-1\""]) }

        let first = try await checker.fetchLatestRelease()
        XCTAssertEqual(first.etag, "\"etag-1\"")

        _ = try await checker.fetchLatestRelease(etag: "\"etag-1\"")
        let last = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
        XCTAssertEqual(last.value(forHTTPHeaderField: "If-None-Match"), "\"etag-1\"")
    }

    func testFetch_304ReturnsNotModified() async throws {
        let checker = makeChecker { _ in .success(status: 304, body: Data(), headers: ["ETag": "\"etag-1\""]) }

        let result = try await checker.fetchLatestRelease(etag: "\"etag-1\"")

        XCTAssertEqual(result.response, .notModified)
        XCTAssertEqual(result.etag, "\"etag-1\"")
    }

    // MARK: - 방어적 무시 (D4)

    func testFetch_draftReleaseIsNotUsable() async throws {
        let checker = makeChecker { _ in .json(self.releaseJSON(draft: true)) }

        let result = try await checker.fetchLatestRelease()

        XCTAssertEqual(result.response, .noUsableRelease, "초안 릴리스를 정식 업데이트로 안내하면 안 된다")
    }

    func testFetch_prereleaseIsNotUsable() async throws {
        let checker = makeChecker { _ in .json(self.releaseJSON(prerelease: true)) }

        let response = try await checker.fetchLatestRelease().response
        XCTAssertEqual(response, .noUsableRelease)
    }

    /// 태그에 프리릴리스 식별자가 붙어 있으면 플래그가 없어도 무시한다.
    func testFetch_prereleaseTagIsNotUsable() async throws {
        let checker = makeChecker { _ in .json(self.releaseJSON(tag: "v0.5.0-beta.1")) }

        let response = try await checker.fetchLatestRelease().response
        XCTAssertEqual(response, .noUsableRelease)
    }

    func testFetch_unparseableTagIsNotUsable() async throws {
        let checker = makeChecker { _ in .json(self.releaseJSON(tag: "nightly")) }

        let response = try await checker.fetchLatestRelease().response
        XCTAssertEqual(response, .noUsableRelease)
    }

    /// `html_url`이 없으면 저장소의 릴리스 페이지로 폴백한다(빈 링크를 사용자에게 주지 않는다).
    func testFetch_missingHTMLURLFallsBackToReleasesPage() async throws {
        let checker = makeChecker { _ in .json(#"{"tag_name":"v0.9.0"}"#) }

        guard case let .release(release) = try await checker.fetchLatestRelease().response else {
            return XCTFail("릴리스를 읽지 못했다")
        }
        XCTAssertEqual(release.pageURL, checker.releasesPageURL)
        XCTAssertEqual(release.title, "v0.9.0", "제목이 없으면 태그로 대체한다")
    }

    // MARK: - `html_url` 스킴 검증 (reviewer major #1)

    /// `html_url`은 응답이 준 문자열이고 최종 목적지는 `NSWorkspace.open`이다.
    /// `https`가 아니면 [Download] 뒤에 로컬 파일 열기가 실리게 되므로 폴백으로 대체해야 한다.
    func testFetch_nonHTTPSPageURLFallsBackToReleasesPage() async throws {
        let hostile = [
            "file:///Applications/Calculator.app",
            "http://github.com/acme/UniFinder/releases/tag/v0.9.0",
            "ftp://example.com/payload",
            "javascript:alert(1)",
            "",
            "   ",
            "not a url at all",
        ]

        for raw in hostile {
            let checker = makeChecker { _ in
                .json(#"{"tag_name":"v0.9.0","html_url":"\#(raw)"}"#)
            }

            guard case let .release(release) = try await checker.fetchLatestRelease().response else {
                return XCTFail("릴리스를 읽지 못했다 (html_url=\(raw))")
            }
            XCTAssertEqual(
                release.pageURL, checker.releasesPageURL,
                "https가 아닌 html_url(\(raw))이 그대로 [Download]에 실렸다 — 코드 내 폴백으로 대체해야 한다"
            )
        }
    }

    /// 폴백 자체는 **코드에 박힌 https 주소**여야 한다(응답이 정하는 값이 아니다).
    func testReleasesPageURL_isHardcodedHTTPS() throws {
        let pageURL = try XCTUnwrap(UpdateChecker().releasesPageURL)
        XCTAssertEqual(pageURL.scheme, "https")
        XCTAssertEqual(pageURL.absoluteString, "https://github.com/ilphs/UniFinder/releases/latest")
    }

    /// 스킴 검사는 대소문자를 가리지 않고, 정상 https 주소는 그대로 통과한다.
    func testSanitizedPageURL_acceptsHTTPSAndRejectsEverythingElse() {
        let fallback = URL(string: "https://github.com/ilphs/UniFinder/releases/latest")!

        XCTAssertEqual(
            UpdateChecker.sanitizedPageURL("HTTPS://github.com/a/b/releases/tag/v1", fallback: fallback)?.absoluteString,
            "HTTPS://github.com/a/b/releases/tag/v1",
            "스킴 대소문자는 URL 규격상 무의미하다 — 정상 주소를 폴백으로 깎아내면 안 된다"
        )
        XCTAssertEqual(UpdateChecker.sanitizedPageURL(nil, fallback: fallback), fallback)
        XCTAssertEqual(UpdateChecker.sanitizedPageURL("https:///no-host", fallback: fallback), fallback)
        XCTAssertEqual(UpdateChecker.sanitizedPageURL("/relative/path", fallback: fallback), fallback)
        XCTAssertNil(
            UpdateChecker.sanitizedPageURL("ftp://example.com", fallback: nil),
            "폴백조차 없으면 열 곳이 없다 — 억지로 주소를 만들어내면 안 된다"
        )
    }

    // MARK: - 주소 조립 안전성 (reviewer minor #1)

    /// `owner`/`repository`는 초기화 파라미터로 열려 있다 — 어떤 문자열이 들어와도
    /// **크래시하지 않고** `nil`이거나 안전한 주소여야 한다(예전에는 `URL(string:)!`이었다).
    func testRepositoryURLs_areNilForNamesOutsideTheAllowedCharacterSet() {
        let hostile = [
            "acme corp",            // 공백
            "acme/../../etc",       // 경로 조작
            "acme/UniFinder",       // 조각 안의 `/`
            "정상아님",               // 유니코드
            "",                     // 빈 문자열
            "acme?x=1",             // 쿼리 주입
            "acme#fragment",
            "acme@evil.com",        // userinfo 주입
        ]

        for name in hostile {
            XCTAssertNil(
                UpdateChecker(owner: name, repository: "UniFinder").latestReleaseURL,
                "owner=\(name)로 API 주소가 만들어졌다"
            )
            XCTAssertNil(
                UpdateChecker(owner: "acme", repository: name).releasesPageURL,
                "repository=\(name)로 릴리스 페이지 주소가 만들어졌다"
            )
        }
    }

    /// 정상 이름은 그대로 통과한다 — 안전 검사가 실사용 이름을 깎아내면 안 된다.
    func testRepositoryURLs_acceptRealisticNames() throws {
        let checker = UpdateChecker(owner: "acme-labs_1", repository: "Uni.Finder")

        XCTAssertEqual(
            try XCTUnwrap(checker.latestReleaseURL).absoluteString,
            "https://api.github.com/repos/acme-labs_1/Uni.Finder/releases/latest"
        )
        XCTAssertEqual(
            try XCTUnwrap(checker.releasesPageURL).absoluteString,
            "https://github.com/acme-labs_1/Uni.Finder/releases/latest"
        )
    }

    /// 주소를 만들 수 없으면 **요청을 보내지 않고** 설정 오류로 끝난다(크래시 대신).
    func testFetch_withUnusableRepositoryNameFailsWithoutRequest() async {
        let checker = UpdateChecker(
            owner: "acme corp/../x",
            repository: "UniFinder",
            session: StubURLProtocol.makeSession { _ in .json("{}") }
        )

        await assertThrows(checker, .invalidRepository)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty, "만들 수 없는 주소로 요청이 나갔다")
    }

    // MARK: - 응답 크기 상한 (reviewer minor #2)

    /// 상한을 넘긴 본문은 **파싱하지 않고** 실패로 끝낸다.
    func testFetch_oversizedBodyIsRejected() async {
        let padding = String(repeating: "x", count: UpdateChecker.maximumResponseBytes)
        let checker = makeChecker { _ in .json(self.releaseJSON(body: padding)) }

        await assertThrows(checker, .invalidResponse)
    }

    /// 상한 **이하**는 그대로 읽는다 — 상한이 정상 릴리스 노트를 잘라내면 안 된다.
    func testFetch_bodyUnderTheLimitIsParsed() async throws {
        let notes = String(repeating: "y", count: 4_000)
        let checker = makeChecker { _ in .json(self.releaseJSON(body: notes)) }

        guard case let .release(release) = try await checker.fetchLatestRelease().response else {
            return XCTFail("상한 이하 응답을 읽지 못했다")
        }
        XCTAssertEqual(release.notes.count, notes.count)
    }

    /// 본문은 **한 번만** 파싱한다 — 파손/쓸 수 없음 판정이 한 경로에서 갈린다.
    func testParse_separatesMalformedFromUnusableInOnePass() {
        let fallback = URL(string: "https://github.com/acme/UniFinder/releases/latest")!

        XCTAssertEqual(UpdateChecker.parse(Data("{ nope".utf8), fallbackPageURL: fallback), .malformed)
        XCTAssertEqual(UpdateChecker.parse(Data("[]".utf8), fallbackPageURL: fallback), .malformed)
        XCTAssertEqual(
            UpdateChecker.parse(Data(#"{"tag_name":"nightly"}"#.utf8), fallbackPageURL: fallback),
            .unusable,
            "형식은 멀쩡한데 태그를 못 읽는 것은 에러가 아니라 '쓸 수 없는 릴리스'다"
        )
        guard case .release = UpdateChecker.parse(Data(releaseJSON().utf8), fallbackPageURL: fallback) else {
            return XCTFail("정상 릴리스를 읽지 못했다")
        }
    }

    // MARK: - 기본 세션 (reviewer minor #3)

    /// `UpdateChecker()`를 여러 번 만들어도 세션이 쌓이지 않는다 —
    /// 기본 fetcher는 **프로세스당 하나뿐인 공유 세션**을 쓴다.
    func testDefaultFetcher_usesASingleSharedSessionAcrossInstances() throws {
        let source = try String(
            contentsOf: ProjectManifest.repositoryRoot
                .appendingPathComponent("src/Services/UpdateChecker.swift"),
            encoding: .utf8
        )
        let lines = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }

        XCTAssertTrue(
            lines.contains { $0.contains("private static let sharedSession: URLSession") },
            "기본 세션이 공유 인스턴스가 아니다 — `UpdateChecker()`마다 세션이 새로 생기면 누수가 쌓인다"
        )
        XCTAssertEqual(
            lines.filter { $0.contains("URLSession(configuration:") }.count, 1,
            "세션을 만드는 지점은 공유 인스턴스 하나뿐이어야 한다(생성마다 만들면 invalidate 없이 누적된다)"
        )
    }

    // MARK: - 실패 경로

    func testFetch_404IsNotFound() async {
        let checker = makeChecker { _ in .json("{}", status: 404) }

        await assertThrows(checker, .notFound)
    }

    func testFetch_403IsRateLimited() async {
        let checker = makeChecker { _ in .json("{}", status: 403) }

        await assertThrows(checker, .rateLimited)
    }

    func testFetch_500IsServerError() async {
        let checker = makeChecker { _ in .json("{}", status: 500) }

        await assertThrows(checker, .server(status: 500))
    }

    func testFetch_timeoutIsMappedToTimedOut() async {
        let checker = makeChecker { _ in .failure(.timedOut) }

        await assertThrows(checker, .timedOut)
    }

    func testFetch_offlineIsMappedToOffline() async {
        let checker = makeChecker { _ in .failure(.notConnectedToInternet) }

        await assertThrows(checker, .offline)
    }

    func testFetch_malformedJSONIsInvalidResponse() async {
        let checker = makeChecker { _ in .json("{ this is not json") }

        await assertThrows(checker, .invalidResponse)
    }

    /// **배포 저장소가 실제 저장소와 일치하는지** — 어긋나면 404가 나는데 자동 확인은 침묵하므로
    /// 아무도 눈치채지 못한 채 업데이트 안내가 영영 죽는다. `INSTALL.md`의 Releases 링크를 근거로 삼는다.
    func testDefaultRepository_matchesDistributionLinkInDocs() throws {
        let install = try String(
            contentsOf: ProjectManifest.repositoryRoot.appendingPathComponent("INSTALL.md"),
            encoding: .utf8
        )
        let expected = "github.com/\(UpdateChecker.defaultOwner)/\(UpdateChecker.defaultRepository)/releases"

        XCTAssertTrue(
            install.contains(expected),
            "업데이트 확인이 바라보는 저장소(\(expected))가 INSTALL.md의 배포 링크와 다르다"
        )
        XCTAssertEqual(
            try XCTUnwrap(UpdateChecker().latestReleaseURL).absoluteString,
            "https://api.github.com/repos/ilphs/UniFinder/releases/latest"
        )
    }

    /// 모든 실패 사유는 사용자에게 보여줄 문장을 갖는다(수동 확인 경로).
    func testErrorMessages_areNonEmpty() {
        let errors: [UpdateCheckError] = [
            .timedOut, .offline, .notFound, .rateLimited, .server(status: 503),
            .invalidResponse, .invalidRepository, .transport("x"),
        ]
        for error in errors {
            XCTAssertFalse(error.message.isEmpty, "\(error)에 사용자 문구가 없다")
        }
    }

    private func assertThrows(
        _ checker: UpdateChecker,
        _ expected: UpdateCheckError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let result = try await checker.fetchLatestRelease()
            XCTFail("에러를 기대했지만 \(result.response)를 받았다", file: file, line: line)
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("예상 밖 에러: \(error)", file: file, line: line)
        }
    }
}
