import AppKit
import Foundation
import Observation

/// 좌측 트리의 노드. `NSOutlineView`가 아이템 동일성을 객체 참조로 판단하므로
/// 값 타입이 아니라 클래스(NSObject)로 둔다 — 확장 상태가 reload를 넘어 유지된다.
@MainActor
final class TreeNode: NSObject {

    enum Kind {
        /// "즐겨찾기" / "홈" / "볼륨" 섹션 헤더 (선택 불가)
        case section
        case folder
        /// 자식 로딩 중 자리를 채우는 회색 1행 (UI설계 §3)
        case placeholder
    }

    let kind: Kind
    let url: URL
    let name: String
    let isSymlink: Bool
    private(set) weak var parent: TreeNode?

    /// `nil` = 아직 로드하지 않음 (lazy). 빈 배열 = 로드했고 하위 폴더가 없음.
    var children: [TreeNode]?

    /// 아웃라인 뷰에서 펼쳐진 상태인지. `expand(_:)`/`reveal(_:)`이 갱신한다.
    var isExpanded: Bool = false

    /// 권한 등으로 열거에 실패하면 `false`. 트리에서 숨기지 않고 회색 처리한다(UI설계 §3).
    var isAccessible: Bool = true

    var isLoading: Bool = false

    /// `TreeModel.invalidate(_:)`가 증가시키는 세대 번호 (m2-impl T1 / architect B8).
    ///
    /// 무효화 직전에 시작된 확장이 뒤늦게 끝나 **낡은 자식 목록을 덮어쓰는 것**을 막는다.
    /// (이름 변경/삭제 직후 도착한 응답이 사라진 폴더를 그대로 되살리는 회귀 방지)
    var loadGeneration: Int = 0

    /// 자식 로딩 중 표시할 placeholder. 노드마다 1개를 재사용해 동일성을 유지한다.
    private(set) lazy var loadingPlaceholder: TreeNode = {
        TreeNode(kind: .placeholder, url: url, name: "불러오는 중…", isSymlink: false, parent: self)
    }()

    init(kind: Kind, url: URL, name: String, isSymlink: Bool, parent: TreeNode?) {
        self.kind = kind
        self.url = url
        self.name = name
        self.isSymlink = isSymlink
        self.parent = parent
        super.init()
    }

    /// 아웃라인 뷰에 실제로 보여줄 자식들 (로딩 중이면 placeholder 1행).
    var displayChildren: [TreeNode] {
        if let children { return children }
        return isLoading ? [loadingPlaceholder] : []
    }

    var isSelectable: Bool { kind == .folder }
}

/// 좌측 트리 상태 (설계서 §2.2, §3.2).
///
/// 섹션 3개(즐겨찾기 / 홈 / 볼륨), 노드는 확장 시점에 1-depth만 로드한다.
/// `reveal(_:)`은 경로 체인을 순차 확장해 우측 pane과 트리를 동기화한다.
@Observable
@MainActor
final class TreeModel {

    /// 순환 심볼릭 링크 방어 — reveal 확장 depth 상한 (구현계획서 T4)
    static let maxRevealDepth = 32

    /// 섹션 노드 3개.
    private(set) var sections: [TreeNode] = []

    /// 브릿지가 `reloadData` 시점을 판단하기 위한 카운터.
    private(set) var revision: Int = 0

    /// `reveal(_:)`이 만든 확장 체인. 브릿지가 소비한 뒤 `consumePendingReveal()`로 비운다.
    private(set) var pendingReveal: [TreeNode]?

    /// 현재 선택되어야 할 노드의 URL.
    private(set) var selectedURL: URL?

    var showHidden: Bool

    private let loader: any DirectoryListing
    private let homeURL: URL

    /// 경로(정규화된 문자열) → 노드. `node(for:)`가 O(1)로 찾는다.
    private var nodeIndex: [String: TreeNode] = [:]

    /// 진행 중인 확장 작업(노드 1개당 최대 1개). 같은 노드에 대한 중복 확장을 막는다.
    ///
    /// 이 방어가 없으면 연속 이동으로 `reveal`이 중첩됐을 때 같은 노드에서 `expand`가 두 번
    /// 진입해 자식 `TreeNode`를 두 벌 만든다. `register`는 먼저 만든 노드를 유지하므로
    /// `nodeIndex`가 트리에 붙어있지 않은 스테일 노드를 가리키게 되고, 이후 `node(for:)`/
    /// `reveal`이 조용히 어긋난다.
    ///
    /// `id`를 함께 들고 있는 이유(m2-impl T1): `invalidate(_:)`가 진행 중인 확장을 취소하고
    /// 곧바로 새 확장을 시작하면, 먼저 시작된 `expand`의 정리 코드가 **새 작업의 항목**을
    /// 지워버릴 수 있다. 정리 시 id를 대조해 자기 작업일 때만 제거한다.
    private struct ExpandEntry {
        let id: Int
        let task: Task<Void, Never>
    }

    private var expandTasks: [ObjectIdentifier: ExpandEntry] = [:]
    private var nextExpandID = 0

    private var volumeObservers: [NSObjectProtocol] = []

    init(
        loader: any DirectoryListing = DirectoryLoader.shared,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        showHidden: Bool = false
    ) {
        self.loader = loader
        self.homeURL = Self.canonicalDirectoryURL(homeURL)
        self.showHidden = showHidden
        rebuildSections()
    }

    /// 볼륨 감시 해제 (윈도우 종료 시).
    func stopObservingVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers {
            center.removeObserver(observer)
        }
        volumeObservers.removeAll()
    }

    // MARK: - 섹션 구성

    /// 섹션/루트 노드를 다시 만든다. 이미 로드된 하위 트리는 URL 기준으로 그대로 이어붙인다.
    func rebuildSections() {
        let previousIndex = nodeIndex
        nodeIndex = [:]

        var newSections: [TreeNode] = []

        // 1) 즐겨찾기 — MVP는 고정 3개 (설계서 §2.2)
        let favorites = TreeNode(kind: .section, url: homeURL, name: "즐겨찾기", isSymlink: false, parent: nil)
        favorites.children = favoriteURLs().map { url in
            makeOrReuseFolderNode(url: url, name: displayName(for: url), parent: favorites, previousIndex: previousIndex)
        }
        favorites.isExpanded = true
        newSections.append(favorites)

        // 2) 홈
        let homeSection = TreeNode(kind: .section, url: homeURL, name: "홈", isSymlink: false, parent: nil)
        let homeNode = makeOrReuseFolderNode(
            url: homeURL,
            name: "홈 (\(NSUserName()))",
            parent: homeSection,
            previousIndex: previousIndex
        )
        homeSection.children = [homeNode]
        homeSection.isExpanded = true
        newSections.append(homeSection)

        // 3) 볼륨 — 로컬 볼륨만 (네트워크 볼륨 제외, 설계서 §1.2 비목표)
        let volumesSection = TreeNode(kind: .section, url: URL(fileURLWithPath: "/"), name: "볼륨", isSymlink: false, parent: nil)
        volumesSection.children = localVolumeURLs().map { url in
            makeOrReuseFolderNode(url: url, name: displayName(for: url), parent: volumesSection, previousIndex: previousIndex)
        }
        volumesSection.isExpanded = true
        newSections.append(volumesSection)

        sections = newSections
        revision &+= 1
    }

    /// 볼륨이 분리됐음을 알린다 (m3-impl T1).
    ///
    /// 트리 갱신은 이 타입이 스스로 처리하지만, "표시 중 경로가 그 볼륨 하위였는지"는
    /// 네비게이션을 아는 `AppModel`만 판단할 수 있어 통지만 올린다.
    /// - Parameter URL: 통지가 실어 준 볼륨 URL. 없을 수도 있다(그 경우 수신자가 존재 여부로 판단).
    @ObservationIgnored
    var onVolumeUnmounted: ((URL?) -> Void)?

    /// 볼륨 마운트/언마운트 감시 시작 (설계서 §6).
    ///
    /// M1은 트리 갱신만 했고, M3 T1에서 **언마운트 통지를 상위로 올린다** —
    /// 표시 중이던 볼륨이 빠지면 홈으로 이동해야 하기 때문이다.
    func startObservingVolumes() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                let isUnmount = name == NSWorkspace.didUnmountNotification
                Task { @MainActor in
                    guard let self else { return }
                    self.rebuildSections()
                    if isUnmount {
                        self.onVolumeUnmounted?(volumeURL)
                    }
                }
            }
            volumeObservers.append(observer)
        }
    }

    private func favoriteURLs() -> [URL] {
        let fileManager = FileManager.default
        let candidates: [FileManager.SearchPathDirectory] = [.desktopDirectory, .downloadsDirectory, .documentDirectory]
        return candidates.compactMap { directory in
            fileManager.urls(for: directory, in: .userDomainMask).first
        }.map(Self.canonicalDirectoryURL)
    }

    private func localVolumeURLs() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeNameKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return [URL(fileURLWithPath: "/")]
        }

        return volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            let isLocal = values.volumeIsLocal ?? false
            let isBrowsable = values.volumeIsBrowsable ?? true
            return isLocal && isBrowsable
        }.map(Self.canonicalDirectoryURL)
    }

    private func displayName(for url: URL) -> String {
        if let values = try? url.resourceValues(forKeys: [.volumeNameKey, .localizedNameKey]) {
            if url.path == "/" || FileManager.default.componentsToDisplay(forPath: url.path)?.count == 1 {
                if let volumeName = values.volumeName, !volumeName.isEmpty {
                    return volumeName
                }
            }
            if let localized = values.localizedName, !localized.isEmpty {
                return localized
            }
        }
        let last = url.lastPathComponent
        return last.isEmpty ? url.path : last
    }

    // MARK: - 조회

    /// 이미 트리에 만들어져 있는 노드를 경로로 찾는다.
    func node(for url: URL) -> TreeNode? {
        nodeIndex[Self.indexKey(url)]
    }

    /// 즐겨찾기 항목·볼륨 루트·홈 루트인지 (m2-impl T0 "위험 대상 가드").
    /// 트리 컨텍스트 메뉴에서 삭제/이름 변경을 비활성화하는 판단 근거다.
    func isProtectedNode(_ node: TreeNode) -> Bool {
        guard node.kind == .folder else { return true }
        // 섹션 바로 아래(즐겨찾기 3개 / 홈 루트 / 볼륨 루트)는 전부 보호 대상
        if node.parent?.kind == .section { return true }
        let key = Self.indexKey(node.url)
        return key == "/" || key == Self.indexKey(homeURL)
    }

    // MARK: - 무효화 (m2-impl T1 / architect B8)

    /// 폴더 내용이 바뀌었음을 트리에 알린다 — 이름 변경·삭제·붙여넣기·새 폴더가 **전부 이 경로를 경유**한다.
    ///
    /// M1의 `nodeIndex`는 등록(`register`)만 있고 제거 경로가 없어서, 트리에서 조작이 일어나면
    /// 인덱스가 옛 경로를 계속 가리키고 이후 `node(for:)`/`reveal`이 조용히 어긋났다.
    ///
    /// 동작:
    /// 1. `url`(없으면 가장 가까운 조상)의 노드를 찾는다
    /// 2. **하위 서브트리의 인덱스 키를 전부 제거**한다 (노드 자신은 트리에 남아 있으므로 유지)
    /// 3. 진행 중인 확장을 취소하고 `children = nil`로 되돌린다
    /// 4. `revision`을 올려 브릿지가 `reloadData`하게 하고, 펼쳐져 있던 노드는 즉시 재확장한다
    ///
    /// 노드 자체가 사라지거나 이름이 바뀐 경우에는 **부모를 무효화**하면 된다 —
    /// 그러면 그 노드가 서브트리째 인덱스에서 빠지고 새 데이터로 다시 만들어진다.
    func invalidate(_ url: URL) {
        guard let node = nearestIndexedNode(for: url) else { return }

        node.loadGeneration &+= 1

        let key = ObjectIdentifier(node)
        if let entry = expandTasks[key] {
            entry.task.cancel()
            expandTasks[key] = nil
        }

        removeDescendantIndexEntries(of: node)
        node.children = nil
        node.isLoading = false
        revision &+= 1

        // 펼쳐진 상태였다면 브릿지의 willExpand가 다시 오지 않으므로 여기서 재로드한다.
        if node.isExpanded {
            expandInBackground(node)
        }
    }

    /// `url`부터 위로 올라가며 인덱스에 등록된 첫 노드를 찾는다.
    /// (아직 확장되지 않은 깊은 경로를 무효화해도 상위 노드 기준으로 정합성이 맞는다)
    private func nearestIndexedNode(for url: URL) -> TreeNode? {
        var candidate: URL? = Self.canonicalDirectoryURL(url)
        for _ in 0..<128 {
            guard let current = candidate else { return nil }
            if let node = nodeIndex[Self.indexKey(current)], node.kind == .folder {
                return node
            }
            candidate = PathKey.parent(of: current)
        }
        return nil
    }

    /// 서브트리(자식 이하)의 인덱스 키를 제거한다.
    /// 심볼릭 링크 순환 등으로 같은 키가 다른 노드를 가리키고 있으면 건드리지 않는다.
    private func removeDescendantIndexEntries(of node: TreeNode) {
        for child in node.children ?? [] {
            removeDescendantIndexEntries(of: child)
            let key = Self.indexKey(child.url)
            if nodeIndex[key] === child {
                nodeIndex.removeValue(forKey: key)
            }
        }
    }

    // MARK: - 확장 (lazy 1-depth)

    /// 노드의 자식을 1-depth만 로드한다. 이미 로드했으면 아무 것도 하지 않는다.
    ///
    /// 같은 노드에 대한 확장이 이미 진행 중이면 새로 열거하지 않고 그 작업의 완료를 기다린다
    /// (재진입 시 자식 노드 중복 생성 → `nodeIndex` 스테일화 방지).
    func expand(_ node: TreeNode) async {
        node.isExpanded = true
        guard node.kind == .folder else { return }
        guard node.children == nil else { return }

        let key = ObjectIdentifier(node)
        if let inFlight = expandTasks[key] {
            await inFlight.task.value
            return
        }

        // 확장 본체는 비구조적 태스크로 감싸 여러 호출자가 하나의 결과를 공유하게 한다.
        // (한 호출자가 취소돼도 나머지 호출자의 확장 결과가 반쪽으로 남지 않는다)
        nextExpandID &+= 1
        let expandID = nextExpandID
        let task = Task { [weak self] () -> Void in
            await self?.performExpand(node)
        }
        expandTasks[key] = ExpandEntry(id: expandID, task: task)
        await task.value
        if expandTasks[key]?.id == expandID {
            expandTasks[key] = nil
        }
    }

    private func performExpand(_ node: TreeNode) async {
        guard node.children == nil else { return }

        // 무효화 세대를 스냅샷해두고, 응답 도착 시점에 대조한다 (m2-impl T1).
        let generation = node.loadGeneration

        node.isLoading = true
        revision &+= 1
        defer {
            node.isLoading = false
        }

        do {
            let entries = try await loader.list(at: node.url, showHidden: showHidden)
            // 열거 도중 이 노드가 무효화됐다면 낡은 결과로 덮어쓰지 않는다.
            guard node.loadGeneration == generation else {
                node.children = nil
                return
            }
            let directories = entries
                .filter(\.isDirectory)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            node.children = directories.map { item in
                let child = TreeNode(
                    kind: .folder,
                    url: Self.canonicalDirectoryURL(item.url),
                    name: item.name,
                    isSymlink: item.isSymlink,
                    parent: node
                )
                register(child)
                return child
            }
            node.isAccessible = true
        } catch is CancellationError {
            node.children = nil
        } catch {
            // 권한 없는 폴더도 트리에서 숨기지 않고 회색 처리한다 (UI설계 §3)
            node.children = []
            node.isAccessible = false
        }
        revision &+= 1
    }

    /// 자식을 아직 모른다면 로드를 시작한다(브릿지의 willExpand에서 호출).
    /// 중복 확장 방어는 `expand(_:)`가 담당하므로 여기서는 빠른 경로만 거른다.
    func expandInBackground(_ node: TreeNode) {
        node.isExpanded = true
        guard node.kind == .folder, node.children == nil else { return }
        Task { [weak self] in
            await self?.expand(node)
        }
    }

    func setCollapsed(_ node: TreeNode) {
        node.isExpanded = false
    }

    // MARK: - reveal

    /// 우측 pane이 이동한 경로에 맞춰 트리를 확장·선택한다 (설계서 §2.2).
    /// 순환 심볼릭 링크 방어를 위해 확장 depth를 `maxRevealDepth`로 제한한다.
    ///
    /// 취소되면(= 다음 이동이 이미 시작됨) 선택/확장 체인을 갱신하지 않고 즉시 빠져나간다.
    func reveal(_ url: URL) async {
        guard !Task.isCancelled else { return }
        let target = Self.canonicalDirectoryURL(url)
        guard let root = bestRoot(for: target) else {
            selectedURL = nil
            return
        }

        var chain: [TreeNode] = [root]
        var node = root

        let components = Self.relativeComponents(of: target, under: root.url)
        var depth = 0

        for component in components {
            if depth >= Self.maxRevealDepth { break }
            depth += 1

            await expand(node)
            // 확장 도중 다음 이동이 시작됐다면 스테일한 선택으로 덮어쓰지 않는다.
            guard !Task.isCancelled else { return }

            guard let child = node.children?.first(where: { $0.name == component }) else {
                break
            }
            chain.append(child)
            node = child
        }

        selectedURL = node.url
        pendingReveal = chain
        revision &+= 1
    }

    /// 브릿지가 확장 체인을 소비한다(1회성).
    func consumePendingReveal() -> [TreeNode]? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    /// 대상 경로를 가장 깊게 포함하는 루트 노드를 고른다.
    /// (홈 하위 경로는 볼륨 `/` 대신 홈 트리에서 전개된다)
    private func bestRoot(for url: URL) -> TreeNode? {
        var best: TreeNode?
        var bestLength = -1

        for section in sections {
            for root in section.children ?? [] {
                guard root.kind == .folder else { continue }
                guard Self.isSameOrDescendant(url, of: root.url) else { continue }
                let length = root.url.path.count
                if length > bestLength {
                    best = root
                    bestLength = length
                }
            }
        }
        return best
    }

    // MARK: - 노드 인덱스

    private func makeOrReuseFolderNode(
        url: URL,
        name: String,
        parent: TreeNode,
        previousIndex: [String: TreeNode]
    ) -> TreeNode {
        if let existing = previousIndex[Self.indexKey(url)], existing.kind == .folder {
            reindex(existing)
            return existing
        }
        let node = TreeNode(kind: .folder, url: url, name: name, isSymlink: false, parent: parent)
        register(node)
        return node
    }

    private func register(_ node: TreeNode) {
        let key = Self.indexKey(node.url)
        // 심볼릭 링크 순환에서 같은 경로가 다시 등장하면 먼저 만든 노드를 유지한다.
        if nodeIndex[key] == nil {
            nodeIndex[key] = node
        }
    }

    private func reindex(_ node: TreeNode) {
        register(node)
        for child in node.children ?? [] {
            reindex(child)
        }
    }

    // MARK: - 경로 유틸

    /// 트리 노드 URL의 표준형(폴더이므로 후행 슬래시 포함).
    /// 심볼릭 링크는 해석하지 않아 `/var` 같은 사용자 표기를 유지한다.
    static func canonicalDirectoryURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard !path.isEmpty else { return URL(fileURLWithPath: "/", isDirectory: true) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 트리 인덱스 키. 목록/클립보드와 같은 기준을 써야 트리 조작 후 조회가 어긋나지 않는다
    /// (m2-impl T4 "URL 표기 정합 규칙" — `PathKey`가 단일 기준).
    static func indexKey(_ url: URL) -> String {
        PathKey.key(url)
    }

    static func isSameOrDescendant(_ url: URL, of base: URL) -> Bool {
        PathKey.isSameOrDescendant(url, of: base)
    }

    /// `base` 기준 상대 경로 컴포넌트 목록.
    ///
    /// 포함 관계 판정은 대소문자를 무시하는 `indexKey`로 하지만, 돌려주는 컴포넌트는
    /// **표기를 보존**해야 한다 — reveal이 `node.name == component`로 자식을 찾기 때문에
    /// 소문자로 뭉갠 컴포넌트를 주면 경로 전개가 통째로 실패한다.
    static func relativeComponents(of url: URL, under base: URL) -> [String] {
        guard isSameOrDescendant(url, of: base), indexKey(url) != indexKey(base) else { return [] }
        // 소문자 변환은 문자 수를 바꿀 수 있으므로(유니코드 케이스 매핑) 오프셋이 아니라
        // 컴포넌트 개수로 잘라낸다.
        let baseComponents = PathKey.exactPath(base).split(separator: "/")
        let components = PathKey.exactPath(url).split(separator: "/")
        guard components.count > baseComponents.count else { return [] }
        return components.dropFirst(baseComponents.count).map(String.init)
    }
}
