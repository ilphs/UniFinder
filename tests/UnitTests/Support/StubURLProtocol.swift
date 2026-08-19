import Foundation

/// 네트워크를 타지 않는 `URLSession` 스텁 (후속 T3 테스트 지원).
///
/// 업데이트 확인은 이 앱에서 **유일하게 네트워크를 쓰는 경로**다(설계서 §1.2 예외). 그 경로를
/// 실제 GitHub에 붙여 검증하면 네트워크 상태·API 한도·릴리스 내용에 따라 결과가 달라져
/// 단언을 쓸 수 없다. 여기서 응답을 통째로 지어낸다.
///
/// 사용법:
/// ```swift
/// let session = StubURLProtocol.makeSession { request in
///     .success(status: 200, body: json, headers: ["ETag": "\"abc\""])
/// }
/// ```
final class StubURLProtocol: URLProtocol {

    /// 요청 1건에 대한 응답 지시.
    enum Stub {
        case success(status: Int, body: Data, headers: [String: String])
        case failure(URLError.Code)

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Stub {
            .success(status: status, body: Data(text.utf8), headers: headers)
        }
    }

    /// 요청 → 응답 결정. 테스트가 갈아끼운다.
    ///
    /// `URLProtocol` 하위 클래스는 시스템이 인스턴스를 만들기 때문에 주입 지점이 static뿐이다.
    /// 병렬 실행에서 서로 밟지 않도록 잠금으로 감싼다.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> Stub)?
    /// 스텁이 실제로 받은 요청들 — 헤더(`If-None-Match`) 검증에 쓴다.
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func setHandler(_ handler: @escaping (URLRequest) -> Stub) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        recorded = []
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        recorded = []
    }

    static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// 스텁만 처리하는 전용 세션.
    static func makeSession(handler: @escaping (URLRequest) -> Stub) -> URLSession {
        setHandler(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch handler(request) {
        case let .success(status, body, headers):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // 304는 본문이 없다 — 실제 서버 동작을 그대로 흉내낸다.
            if status != 304, !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)

        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
