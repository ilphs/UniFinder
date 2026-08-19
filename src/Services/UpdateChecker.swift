import Foundation

/// GitHub Releases의 최신 릴리스 1건 (후속 T3).
struct UpdateRelease: Sendable, Equatable {

    /// 태그에서 해석한 버전(`v0.4.0` → `0.4.0`).
    let version: SemanticVersion
    /// 원본 태그 문자열 — 표시가 아니라 진단용(어떤 태그를 읽었는지 로그에 남긴다).
    let tagName: String
    /// 릴리스 제목. 비어 있으면 표시 시 태그로 대체한다.
    let title: String
    /// 릴리스 노트 원문. **마크다운을 렌더링하지 않고 일반 텍스트로 보여준다**(UI설계 §7.9).
    let notes: String
    /// 릴리스 페이지. [Download]가 브라우저로 여는 곳이다(앱은 내려받지 않는다).
    let pageURL: URL
}

/// 업데이트 확인 1회의 결과.
enum UpdateCheckResponse: Sendable, Equatable {
    /// 유효한 릴리스를 읽었다(새 버전인지 아닌지는 호출자가 판단한다).
    case release(UpdateRelease)
    /// `If-None-Match`가 맞아 304를 받았다 — 본문이 없으므로 캐시를 쓴다.
    case notModified
    /// 응답은 정상인데 쓸 수 있는 릴리스가 아니다(초안·프리릴리스·해석 불가 태그).
    case noUsableRelease
}

struct UpdateCheckResult: Sendable, Equatable {
    let response: UpdateCheckResponse
    /// 다음 요청에 실을 `ETag`. 없으면 `nil`.
    let etag: String?
}

/// 업데이트 확인 실패 사유.
///
/// **사용자에게 보이는 문구는 수동 확인일 때만 쓴다**(D4 — 자동 확인 실패는 완전 침묵).
enum UpdateCheckError: Error, Equatable {
    case timedOut
    case offline
    /// 저장소나 릴리스가 없다(404). 오탈자 난 owner/repo 설정도 여기로 온다.
    case notFound
    /// 인증 없는 GitHub API의 시간당 한도(403/429).
    case rateLimited
    case server(status: Int)
    /// 응답 본문이 예상과 다르다(JSON 파손, 필드 누락 등). 본문이 상한을 넘긴 경우도 여기다.
    case invalidResponse
    /// `owner`/`repository`로 요청 주소를 만들 수 없다 — 설정이 잘못된 것이지 서버 탓이 아니다.
    /// (reviewer minor #1: 예전에는 `URL(string:)!`이 여기서 크래시를 냈다.)
    case invalidRepository
    case transport(String)

    /// 알림에 그대로 넣는 문장 (UI 문자열이므로 영어).
    var message: String {
        switch self {
        case .timedOut:
            return "The request timed out. Check your internet connection and try again."
        case .offline:
            return "You appear to be offline. Check your internet connection and try again."
        case .notFound:
            return "The release information couldn't be found on the server."
        case .rateLimited:
            return "Too many requests were made to GitHub. Try again later."
        case let .server(status):
            return "The server returned an unexpected response (HTTP \(status))."
        case .invalidResponse:
            return "The release information couldn't be read."
        case .invalidRepository:
            return "The update source is misconfigured, so the check couldn't be performed."
        case let .transport(detail):
            return "The update check failed: \(detail)"
        }
    }
}

/// GitHub Releases REST API로 최신 릴리스를 읽는다 (후속 T3 / D4).
///
/// **이 앱에서 유일하게 네트워크를 쓰는 지점이다.** 설계서 §1.2가 못 박은 경계 4개를
/// 코드로 지키는 곳이기도 하다:
/// (a) `GET`만 한다 (b) 릴리스 **메타데이터**만 읽고 바이너리는 내려받지 않는다
/// (c) 인증 헤더를 붙이지 않는다 (d) 호출 여부는 `UpdatePreferences.autoCheckEnabled`가 정한다.
///
/// **세션을 주입 가능하게 둔다** (`FullDiskAccessModel.opener` 선례): 테스트가 실제 GitHub에
/// 붙으면 네트워크 상태·API 한도에 결과가 좌우돼 단언을 쓸 수 없다. `URLProtocol` 스텁을 끼운
/// `URLSession`을 넘기면 응답을 그대로 지어낼 수 있다.
struct UpdateChecker: Sendable {

    /// 요청 1건을 수행하는 경로. 기본 구현은 `URLSession.data(for:)`.
    typealias Fetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// 요청 timeout(초) — D4.
    static let requestTimeout: TimeInterval = 10
    /// 리소스 timeout(초) — 세션을 직접 만들 때 쓴다.
    static let resourceTimeout: TimeInterval = 20

    /// 읽어들일 응답 본문의 상한(1MB) — reviewer minor #2.
    ///
    /// 우리가 파싱하는 것은 필드 5개짜리 JSON 하나다. 정상 응답은 수 KB이고, 릴리스 노트가
    /// 아무리 길어도 1MB에 닿지 않는다. 상한이 없으면 오염되거나 오작동하는 서버가 보낸
    /// 임의 크기의 본문을 그대로 메모리에 올린 뒤 `JSONSerialization`에 넘기게 된다 —
    /// **이 앱에서 유일한 네트워크 지점**에 그런 무제한 입구를 열어 둘 이유가 없다.
    /// 넘으면 파싱을 시도하지 않고 `invalidResponse`로 끝낸다.
    static let maximumResponseBytes = 1 * 1024 * 1024

    /// 배포 저장소 — `INSTALL.md`의 Releases 링크와 **같은 곳**이어야 한다.
    /// 어긋나면 사용자는 404 때문에 업데이트를 영영 안내받지 못하고(자동 확인은 침묵하므로
    /// 아무도 눈치채지 못한다), 수동 확인은 "서버에서 릴리스 정보를 찾을 수 없다"만 반복한다.
    /// `UpdateCheckerTests`가 문서와 코드를 대조해 감시한다.
    static let defaultOwner = "ilphs"
    static let defaultRepository = "UniFinder"

    let owner: String
    let repository: String

    private let fetcher: Fetcher

    init(
        owner: String = UpdateChecker.defaultOwner,
        repository: String = UpdateChecker.defaultRepository,
        fetcher: @escaping Fetcher = UpdateChecker.defaultFetcher()
    ) {
        self.owner = owner
        self.repository = repository
        self.fetcher = fetcher
    }

    /// 세션을 그대로 받는 편의 초기화 — 테스트가 `URLProtocol` 스텁 세션을 끼운다.
    init(owner: String = UpdateChecker.defaultOwner, repository: String = UpdateChecker.defaultRepository, session: URLSession) {
        self.init(owner: owner, repository: repository, fetcher: { request in
            try await session.data(for: request)
        })
    }

    /// 기본 세션 — 리소스 timeout까지 못 박은 전용 구성을 쓴다.
    ///
    /// **프로세스당 하나만 만든다**(reviewer minor #3). `URLSession`은 쓰고 버리는 값이 아니라
    /// 내부 스레드·큐·연결 풀을 들고 있는 객체이고, `invalidate` 없이 버리면 그대로 남는다.
    /// 예전에는 `UpdateChecker()`를 만들 때마다 새 세션이 생겼는데, 그 생성자는
    /// `AppEnvironment.init` 경로에 있어 **테스트가 인스턴스를 만들 때마다 세션이 쌓였다**.
    /// 공유 인스턴스는 그 누수를 원천에서 없앤다 — 구성이 고정값뿐이라 공유해도 잃는 것이 없다.
    ///
    /// `URLSession.shared`를 쓰지 않는 이유는 그대로다: timeout이 앱 전역 기본값(60s/7일)이라
    /// 끊긴 네트워크에서 확인 작업이 몇 분씩 살아 있게 된다.
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func defaultFetcher() -> Fetcher {
        { request in try await sharedSession.data(for: request) }
    }

    /// GitHub 사용자/저장소 이름에 쓸 수 있는 문자 — 영숫자와 `-`, `_`, `.`뿐이다.
    ///
    /// 이 목록을 **화이트리스트로** 쓴다(퍼센트 인코딩으로 얼버무리지 않는다): `owner`에 `/`가
    /// 섞이면 인코딩 여부와 무관하게 경로 구조 자체가 달라져 엉뚱한 저장소를 가리키게 되고,
    /// 공백·유니코드는 GitHub 이름 규칙에 애초에 없다. 규칙 밖 값은 주소를 만들지 않는다(`nil`).
    private static let allowedNameCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    /// 경로 한 조각으로 그대로 쓸 수 있는 이름인지.
    static func isValidPathSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment.count <= 100 else { return false }
        return segment.unicodeScalars.allSatisfy { allowedNameCharacters.contains($0) }
    }

    /// `https://<host>/<segments…>` 조립 — reviewer minor #1.
    ///
    /// `owner`/`repository`는 **초기화 파라미터로 열려 있는 값**이라(테스트가 임의 문자열을 넣는다)
    /// 문자열 보간 + `URL(string:)!`은 언젠가 크래시하는 코드다. 조각을 하나씩 검사하고
    /// `URLComponents`로 조립해, 만들 수 없으면 크래시 대신 `nil`을 돌려준다.
    static func makeURL(host: String, segments: [String]) -> URL? {
        guard segments.allSatisfy(isValidPathSegment) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/" + segments.joined(separator: "/")
        return components.url
    }

    /// 릴리스 조회 API 주소. `owner`/`repository`가 이름 규칙을 벗어나면 `nil`이다.
    var latestReleaseURL: URL? {
        Self.makeURL(host: "api.github.com", segments: ["repos", owner, repository, "releases", "latest"])
    }

    /// 릴리스 페이지(브라우저로 열 폴백 주소). 응답의 `html_url`이 없을 때 쓴다.
    var releasesPageURL: URL? {
        Self.makeURL(host: "github.com", segments: [owner, repository, "releases", "latest"])
    }

    /// - Parameter etag: 직전 응답의 `ETag`. 있으면 `If-None-Match`로 보내 304를 노린다.
    func fetchLatestRelease(etag: String? = nil) async throws -> UpdateCheckResult {
        // 주소를 만들 수 없으면 요청 자체가 성립하지 않는다 — 예전에는 여기서 크래시했다.
        guard let url = latestReleaseURL else { throw UpdateCheckError.invalidRepository }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        // GitHub이 권장하는 버전 고정 헤더 — 미래의 응답 형식 변경에서 우리를 보호한다.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("UniFinder/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetcher(request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw UpdateCheckError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed:
                throw UpdateCheckError.offline
            case .cancelled: throw CancellationError()
            default: throw UpdateCheckError.transport(error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdateCheckError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }

        let newETag = http.value(forHTTPHeaderField: "ETag")

        switch http.statusCode {
        case 200:
            break
        case 304:
            return UpdateCheckResult(response: .notModified, etag: newETag ?? etag)
        case 403, 429:
            throw UpdateCheckError.rateLimited
        case 404:
            throw UpdateCheckError.notFound
        default:
            throw UpdateCheckError.server(status: http.statusCode)
        }

        // 본문 상한 — 파싱 **전에** 자른다(넘긴 본문은 읽지 않는다).
        guard data.count <= Self.maximumResponseBytes else { throw UpdateCheckError.invalidResponse }

        // **본문은 한 번만 파싱한다**(reviewer minor #2). 예전에는 실패 경로에서 같은 데이터를
        // `parseRelease` → `isDecodableJSONObject`로 두 번 읽어, 파손 여부를 다시 판정했다.
        switch Self.parse(data, fallbackPageURL: releasesPageURL) {
        case let .release(release):
            return UpdateCheckResult(response: .release(release), etag: newETag)
        case .unusable:
            // 형식은 정상인데 우리가 쓸 수 없는 릴리스다 — 에러가 아니라 정상 응답이다.
            return UpdateCheckResult(response: .noUsableRelease, etag: newETag)
        case .malformed:
            throw UpdateCheckError.invalidResponse
        }
    }

    // MARK: - 파싱

    /// 본문 1건을 읽은 결과. **"파손"과 "쓸 수 없음"을 한 번의 파싱으로 가른다** —
    /// 전자는 에러(서버가 이상하다), 후자는 정상 응답(안내할 릴리스가 없을 뿐)이다.
    enum ParseOutcome: Equatable {
        case release(UpdateRelease)
        /// JSON 객체이긴 하지만 초안·프리릴리스·해석 불가 태그라 쓸 수 없다.
        case unusable
        /// JSON 객체조차 아니다.
        case malformed
    }

    /// GitHub 응답에서 릴리스를 뽑는다. `Codable` 대신 `JSONSerialization`을 쓰는 이유:
    /// 이 API는 필드가 수십 개인데 우리가 보는 것은 5개뿐이고, 나머지 필드의 타입이 바뀌어도
    /// (GitHub은 실제로 종종 바꾼다) 우리 파싱이 깨지면 안 된다.
    ///
    /// - Parameter fallbackPageURL: `html_url`이 없거나 안전하지 않을 때 쓸 주소.
    ///   `nil`이면(= 저장소 이름이 이상해 주소를 못 만든 경우) [Download]가 열 곳이 없으므로
    ///   릴리스를 쓸 수 없는 것으로 본다.
    static func parse(_ data: Data, fallbackPageURL: URL?) -> ParseOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .malformed }

        // 방어적 무시 (D4): `/releases/latest`는 원래 초안·프리릴리스를 제외하지만,
        // 서버가 규칙을 바꿔도 우리가 프리릴리스를 정식 업데이트로 안내하는 일은 없어야 한다.
        if object["draft"] as? Bool == true { return .unusable }
        if object["prerelease"] as? Bool == true { return .unusable }

        guard let tag = object["tag_name"] as? String,
              let version = SemanticVersion(tag),
              !version.isPrerelease
        else { return .unusable }

        guard let pageURL = sanitizedPageURL(object["html_url"] as? String, fallback: fallbackPageURL) else {
            return .unusable
        }

        let title = (object["name"] as? String) ?? ""
        let notes = (object["body"] as? String) ?? ""

        return .release(UpdateRelease(
            version: version,
            tagName: tag,
            title: title.isEmpty ? tag : title,
            notes: notes,
            pageURL: pageURL
        ))
    }

    /// `html_url`을 **브라우저로 열어도 되는 주소인지** 검사한다 (reviewer major #1).
    ///
    /// 이 값은 우리가 만든 것이 아니라 **응답 본문이 준 문자열**이고, 최종 목적지는
    /// `NSWorkspace.open` — 즉 사용자의 머신에서 실행되는 열기 동작이다. 응답이 오염되면
    /// (중간자·설정 오타로 엉뚱한 호스트를 보게 된 경우 포함) `file:///…`이나 커스텀 스킴이
    /// 그대로 [Download] 버튼 뒤에 실린다. `https`만 통과시키고 나머지는 **코드에 박힌**
    /// 릴리스 페이지로 대체한다 — 폴백은 응답이 아니라 우리가 만든 주소라 항상 안전하다.
    ///
    /// 호스트까지는 강제하지 않는다: 저장소를 옮기거나 GitHub Enterprise를 쓰는 경우가
    /// 정상 경로로 남아 있어야 하고, 위험의 본질은 호스트가 아니라 **스킴**이기 때문이다.
    static func sanitizedPageURL(_ raw: String?, fallback: URL?) -> URL? {
        guard let raw,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return fallback }
        return url
    }
}
