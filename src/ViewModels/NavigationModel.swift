import Foundation
import Observation

/// 현재 경로 + 방문 히스토리 (설계서 §3.2).
///
/// 브라우저 관례를 따른다: 새 이동 시 forward 스택을 비우고, 같은 경로로의 재이동은
/// 히스토리를 오염시키지 않는다. 루트(`/`)에서 `goUp()`은 no-op.
@Observable
@MainActor
final class NavigationModel {

    private(set) var currentURL: URL
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { Self.parent(of: currentURL) != nil }

    init(startURL: URL) {
        self.currentURL = Self.normalize(startURL)
    }

    convenience init() {
        self.init(startURL: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - 이동

    func navigate(to url: URL) {
        let target = Self.normalize(url)
        guard target != currentURL else { return }

        backStack.append(currentURL)
        forwardStack.removeAll()
        currentURL = target
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        currentURL = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        currentURL = next
    }

    func goUp() {
        guard let parent = Self.parent(of: currentURL) else { return }
        navigate(to: parent)
    }

    /// 히스토리를 건드리지 않고 현재 위치만 바꾼다.
    /// (표시 중인 폴더가 사라져 상위로 강제 이동하는 경우 — 설계서 §6)
    func replaceCurrent(with url: URL) {
        currentURL = Self.normalize(url)
    }

    // MARK: - 경로 유틸

    /// 상위 폴더. 루트에서는 `nil`.
    static func parent(of url: URL) -> URL? {
        let normalized = normalize(url)
        let parent = normalize(normalized.deletingLastPathComponent())
        return parent == normalized ? nil : parent
    }

    /// 히스토리 비교가 안정적으로 동작하도록 경로 표기를 통일한다.
    /// (`deletingLastPathComponent()`가 남기는 후행 슬래시 제거, `.`/`..` 정리)
    /// 심볼릭 링크는 **해석하지 않는다** — 사용자가 입력/클릭한 경로 표기를 유지해야 하기 때문.
    static func normalize(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard !path.isEmpty else { return URL(fileURLWithPath: "/") }
        return URL(fileURLWithPath: path, isDirectory: false)
    }
}
