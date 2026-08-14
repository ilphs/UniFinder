import Foundation
@testable import UniFinder

/// `DirectoryListing` 프로토콜(architect B3, T1)을 준수하는 테스트 더블.
/// URL별로 결과/에러/지연(게이트)을 설정할 수 있어 `DirectoryModel`의
/// "빠른 연속 이동 시 마지막 요청만 반영" race 조건을 결정적으로 재현한다.
///
/// **조회 키는 `PathKey`다** (m3-impl T0 시점 보강): URL 값으로 직접 키를 잡으면
/// `Fixture.makeDirectory`가 만드는 폴더 URL(후행 슬래시 있음)과 `NavigationModel.normalize`가
/// 만드는 URL(후행 슬래시 없음)이 서로 다른 키가 되어, 설정해둔 결과 대신 조용히 빈 배열이
/// 돌아온다(테스트가 실패가 아니라 **타임아웃**으로 나타나 원인을 찾기 어렵다).
/// 프로덕션이 이미 `PathKey`를 단일 비교 기준으로 쓰므로 더블도 같은 기준을 쓴다.
actor MockDirectoryListing: DirectoryListing {

    private struct Config {
        var items: [FileItem] = []
        var error: DirectoryError?
    }

    private var configs: [String: Config] = [:]
    private(set) var callCounts: [String: Int] = [:]

    /// 게이트가 걸린 URL: list(at:)가 openGate(for:) 호출 전까지 suspend된다.
    private var gatedURLs: Set<String> = []
    private var waitingContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    /// openGate가 list(at:) 호출보다 먼저 도착한 경우를 위한 표시.
    private var preOpenedURLs: Set<String> = []

    func configure(url: URL, items: [FileItem]) {
        configs[PathKey.key(url)] = Config(items: items, error: nil)
    }

    func configure(url: URL, error: DirectoryError) {
        configs[PathKey.key(url)] = Config(items: [], error: error)
    }

    func callCount(for url: URL) -> Int {
        callCounts[PathKey.key(url)] ?? 0
    }

    /// 이 URL에 대한 다음 list(at:) 호출을 openGate(for:)가 불릴 때까지 붙잡아둔다.
    func hold(url: URL) {
        gatedURLs.insert(PathKey.key(url))
    }

    /// hold(url:)로 붙잡아둔 호출을 재개시킨다. list(at:)가 아직 도달하지 않았다면
    /// 먼저 도착한 것으로 표시해두어 이후 호출이 즉시 통과하게 한다.
    func openGate(for url: URL) {
        let key = PathKey.key(url)
        if let cont = waitingContinuations.removeValue(forKey: key) {
            cont.resume()
        } else {
            preOpenedURLs.insert(key)
        }
        gatedURLs.remove(key)
    }

    func list(at url: URL, showHidden: Bool) async throws -> [FileItem] {
        let key = PathKey.key(url)
        incrementCallCount(key)
        await waitForGateIfNeeded(key)
        try Task.checkCancellation()
        return try result(for: key)
    }

    private func incrementCallCount(_ key: String) {
        callCounts[key, default: 0] += 1
    }

    private func waitForGateIfNeeded(_ key: String) async {
        guard gatedURLs.contains(key) else { return }
        if preOpenedURLs.remove(key) != nil {
            gatedURLs.remove(key)
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waitingContinuations[key] = cont
        }
    }

    private func result(for key: String) throws -> [FileItem] {
        guard let config = configs[key] else { return [] }
        if let error = config.error {
            throw error
        }
        return config.items
    }
}
