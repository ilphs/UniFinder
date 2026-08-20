import AppKit
import Foundation
import Observation

/// 좌측 트리의 노드. `NSOutlineView`가 아이템 동일성을 객체 참조로 판단하므로
/// 값 타입이 아니라 클래스(NSObject)로 둔다 — 확장 상태가 reload를 넘어 유지된다.
@MainActor
final class TreeNode: NSObject {

    enum Kind {
        /// 즐겨찾기 / 홈 / 볼륨 섹션 헤더 (선택 불가)
        case section
        case folder
        /// 자식 로딩 중 자리를 채우는 회색 1행 (UI설계 §3)
        case placeholder
    }

    /// 섹션의 종류. **이름 문자열이 아니라 이 값으로** 섹션을 식별한다 —
    /// 헤더 문구는 표시용이라 언제든 바뀔 수 있고(2026-08-18 영어화가 실제로 그랬다),
    /// 문자열 매핑에 기대면 그때마다 아이콘·역할 판정이 조용히 깨진다.
    enum SectionKind {
        case favorites
        case home
        case volumes

        /// 섹션 헤더 아이콘 (SF Symbols).
        var symbolName: String {
            switch self {
            case .favorites: return "star"
            case .home: return "house"
            case .volumes: return "internaldrive"
            }
        }
    }

    let kind: Kind
    let url: URL
    let name: String
    let isSymlink: Bool
    /// 섹션 노드일 때만 값이 있다. 폴더/placeholder는 `nil`.
    let sectionKind: SectionKind?
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
        TreeNode(kind: .placeholder, url: url, name: "Loading…", isSymlink: false, parent: self)
    }()

    init(
        kind: Kind,
        url: URL,
        name: String,
        isSymlink: Bool,
        parent: TreeNode?,
        sectionKind: SectionKind? = nil
    ) {
        self.kind = kind
        self.url = url
        self.name = name
        self.isSymlink = isSymlink
        self.sectionKind = sectionKind
        self.parent = parent
        super.init()
    }

    /// 섹션 재구성 시 **재사용된 노드를 새 부모에 다시 잇는다** (2026-08-18 회귀 수정).
    ///
    /// `rebuildSections()`는 섹션 노드를 매번 새로 만들어 `sections`를 통째로 교체한다.
    /// 그런데 그 아래 루트들은 `makeOrReuseFolderNode`가 옛 인덱스에서 **재사용**하므로,
    /// 재연결을 하지 않으면 옛 섹션 노드가 해제되는 순간 `parent`(weak)가 `nil`이 된다.
    /// 그러면 `isVolumeRoot`가 false로 뒤집혀 볼륨이 폴더 아이콘으로 폴백했다
    /// (즐겨찾기 추가/해제가 rebuild를 상시로 만들면서 드러났다).
    ///
    /// **`parent`는 `weak`을 유지해야 한다** — `children`이 strong 배열이라 strong으로 바꾸면
    /// 부모↔자식 순환 참조가 생겨 트리 전체가 누수된다. 그래서 소유권이 아니라
    /// 이 재연결 경로로 해결한다.
    func reattach(to newParent: TreeNode?) {
        parent = newParent
    }

    /// 아웃라인 뷰에 실제로 보여줄 자식들 (로딩 중이면 placeholder 1행).
    var displayChildren: [TreeNode] {
        if let children { return children }
        return isLoading ? [loadingPlaceholder] : []
    }

    var isSelectable: Bool { kind == .folder }

    /// 볼륨 섹션 바로 아래의 루트 노드인지 — 공용 폴더 아이콘 대신 **실제 디스크 아이콘**을 쓸 대상.
    var isVolumeRoot: Bool {
        kind == .folder && parent?.sectionKind == .volumes
    }

    /// 즐겨찾기 섹션 바로 아래의 항목인지 — "즐겨찾기에서 제거"의 대상 판정에 쓴다.
    var isFavoriteEntry: Bool {
        kind == .folder && parent?.sectionKind == .favorites
    }
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

    /// 섹션이 다시 구성된 횟수 (2026-08-18 C단계).
    ///
    /// `revision`은 노드 확장/로딩마다 올라가므로 **섹션 재구성 시점에만** 무효화하면 되는
    /// 파생 데이터(볼륨 아이콘 캐시)를 거기에 묶으면 스크롤 중 캐시가 통째로 버려진다.
    /// 그래서 별도 카운터로 분리한다.
    private(set) var sectionsRevision: Int = 0

    /// `reveal(_:)`이 만든 확장 체인. 브릿지가 소비한 뒤 `consumePendingReveal()`로 비운다.
    private(set) var pendingReveal: [TreeNode]?

    /// 현재 선택되어야 할 노드의 URL.
    private(set) var selectedURL: URL?

    var showHidden: Bool

    private let loader: any DirectoryListing
    private let homeURL: URL

    /// 즐겨찾기 저장소 (2026-08-18). 트리는 이 목록을 **표시만** 하고 편집은 `AppModel`이 한다.
    private let settings: AppSettings

    /// 경로(정규화된 문자열) → 노드. `node(for:)`가 O(1)로 찾는다.
    private var nodeIndex: [String: TreeNode] = [:]

    /// 볼륨 루트 경로 키 — 위험 대상 가드(`isProtectedURL`)가 쓰는 근거.
    ///
    /// 트리를 거슬러 올라가 "볼륨 섹션 바로 아래인가"를 보는 대신, 볼륨 목록을 아는
    /// 유일한 지점인 `localVolumeURLs()`의 결과를 `rebuildSections()`에서 그대로 받아 둔다.
    /// 마운트/언마운트 통지가 전부 `rebuildSections()`를 경유하므로 목록과 항상 같은 시점의 값이다.
    private var volumeRootKeys: Set<String> = []

    /// 그중 **꺼낼 수 있는** 볼륨의 인덱스 키 (Eject 항목의 유일한 근거).
    ///
    /// `volumeRootKeys`와 같은 시점(`rebuildSections()`)에 확정한다 — 우클릭 시점에 볼륨 속성을
    /// 다시 조회하면 응답 없는 마운트가 하나 끼는 순간 컨텍스트 메뉴가 멈춘다(`VolumeService`
    /// `resourceKeys` 주석). 마운트/언마운트/볼륨 rename 통지가 전부 `rebuildSections()`를
    /// 경유하므로 이 캐시는 목록과 항상 같은 시점의 값이다.
    private var ejectableVolumeKeys: Set<String> = []

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

    /// 볼륨 섹션의 원본 (후속 T1 — 열거 규칙은 `VolumeService`가 소유한다).
    private let volumeService: VolumeService

    /// - Parameter settings: 즐겨찾기 저장소. 테스트는 `AppSettings(defaults: UserDefaults(suiteName:))`로
    ///   격리된 인스턴스를 넘겨 실제 사용자 설정을 건드리지 않는다.
    /// - Parameter volumeService: 볼륨 열거기. 테스트는 가짜 목록을 주입해 실제 마운트 상태에서
    ///   자유로워진다(`FullDiskAccessModel.opener`와 같은 주입 패턴).
    init(
        loader: any DirectoryListing = DirectoryLoader.shared,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        showHidden: Bool = false,
        settings: AppSettings? = nil,
        volumeService: VolumeService = VolumeService()
    ) {
        self.loader = loader
        self.homeURL = Self.canonicalDirectoryURL(homeURL)
        self.showHidden = showHidden
        self.settings = settings ?? AppSettings()
        self.volumeService = volumeService
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

        // 1) 즐겨찾기 — `AppSettings`가 소유하는 편집 가능 목록 (설계서 §2.2, 2026-08-18)
        let favorites = TreeNode(
            kind: .section,
            url: homeURL,
            name: "Favorites",
            isSymlink: false,
            parent: nil,
            sectionKind: .favorites
        )
        favorites.children = favoriteURLs().map { url in
            makeOrReuseFolderNode(url: url, name: displayName(for: url), parent: favorites, previousIndex: previousIndex)
        }
        favorites.isExpanded = true
        newSections.append(favorites)

        // 2) 홈
        let homeSection = TreeNode(
            kind: .section,
            url: homeURL,
            name: "Home",
            isSymlink: false,
            parent: nil,
            sectionKind: .home
        )
        let homeNode = makeOrReuseFolderNode(
            url: homeURL,
            name: "Home (\(NSUserName()))",
            parent: homeSection,
            previousIndex: previousIndex
        )
        homeSection.children = [homeNode]
        homeSection.isExpanded = true
        newSections.append(homeSection)

        // 3) 볼륨 — 로컬 볼륨만 (네트워크 볼륨 제외, 설계서 §1.2 비목표)
        let volumesSection = TreeNode(
            kind: .section,
            url: URL(fileURLWithPath: "/"),
            name: "Volumes",
            isSymlink: false,
            parent: nil,
            sectionKind: .volumes
        )
        // 속성까지 함께 받는다 — Eject 적격 판정을 여기서 확정하기 위함이다(추가 조회 없음).
        let volumes = localVolumes()
        let volumeURLs = volumes.map(\.url)
        // 위험 대상 가드가 쓸 근거를 여기서 확정한다 — 볼륨 목록을 아는 자리가 여기뿐이다.
        // `/`는 목록 조회가 실패해도 항상 보호 대상이라 무조건 넣는다(기존 판정과 동일).
        volumeRootKeys = Set(volumeURLs.map(Self.indexKey))
        volumeRootKeys.insert(Self.indexKey(URL(fileURLWithPath: "/", isDirectory: true)))
        ejectableVolumeKeys = Set(volumes.filter(\.isEjectable).map { Self.indexKey($0.url) })
        volumesSection.children = volumeURLs.map { url in
            makeOrReuseFolderNode(url: url, name: displayName(for: url), parent: volumesSection, previousIndex: previousIndex)
        }
        volumesSection.isExpanded = true
        newSections.append(volumesSection)

        sections = newSections
        revision &+= 1
        sectionsRevision &+= 1
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

    /// 표시할 즐겨찾기 목록 — 저장소 순서를 유지하되 **지금 존재하는 폴더만** 남긴다.
    ///
    /// **유령 경로를 저장소에서 즉시 지우지 않는 이유**: 외장 볼륨이 잠깐 빠졌거나
    /// 네트워크/암호화 볼륨이 아직 마운트되지 않은 상태에서 트리를 한 번 그린 것만으로
    /// 등록을 잃으면 복구 수단이 없다(사용자가 다시 찾아가 등록해야 한다). 반대로 표시에서만
    /// 빼면 볼륨이 돌아온 순간 `rebuildSections`가 다시 보여준다 — 손실 없는 쪽으로 기운다.
    /// 정리는 사용자가 명시적으로 "즐겨찾기에서 제거"할 때만 일어난다.
    private func favoriteURLs() -> [URL] {
        settings.favoriteURLs
            .map(Self.canonicalDirectoryURL)
            .filter { url in
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return exists && isDirectory.boolValue
            }
    }

    /// 볼륨 목록은 **`VolumeService`가 유일한 권위**다 (후속 T1).
    ///
    /// 열거·필터 규칙을 여기에 다시 적으면 디스크 용량 창(T8)과 사이드바가 서로 다른 볼륨을
    /// 보여주게 된다. `FileManager`의 볼륨 열거 API를 직접 부르는 곳은
    /// **`VolumeService` 하나뿐**이어야 한다(`VolumeServiceTests`가 소스 전체를 훑어 감시한다).
    private func localVolumes() -> [VolumeService.LocalVolume] {
        volumeService.localVolumes()
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
    ///
    /// **트리 토폴로지에 기대지 않는다** (2026-08-18 회귀 수정): 예전에는 `parent?.kind == .section`
    /// 으로 "섹션 바로 아래인가"를 봤는데, `parent`는 `weak`이라 섹션 재구성이 한 번만 어긋나도
    /// 가드가 조용히 풀렸다 — 경로 폴백(`/`·홈)이 있는 볼륨/홈 루트와 달리 **즐겨찾기 항목은
    /// 대체 근거가 없어** 곧바로 rename/삭제가 열렸다. 지금은 노드가 트리 어디에 붙어 있든
    /// URL만으로 같은 결론을 낸다.
    func isProtectedNode(_ node: TreeNode) -> Bool {
        guard node.kind == .folder else { return true }
        return isProtectedURL(node.url)
    }

    /// 경로만으로 판정하는 위험 대상 가드 — 홈 루트 / 볼륨 루트 / 즐겨찾기 등록 경로.
    ///
    /// 즐겨찾기는 `settings`가, 볼륨 루트는 `localVolumeURLs()`가 유일한 권위다.
    /// 트리에 노드가 아직 만들어지지 않은 경로도 이 함수로 판정할 수 있다.
    func isProtectedURL(_ url: URL) -> Bool {
        let key = Self.indexKey(url)
        if key == Self.indexKey(homeURL) { return true }
        if volumeRootKeys.contains(key) { return true }
        return settings.isFavorite(url)
    }

    /// 이 경로가 **꺼낼 수 있는 볼륨의 루트**인지 (Eject 메뉴 항목의 유일한 근거).
    ///
    /// 사이드바 트리와 우측 목록(`/Volumes`를 열었을 때)이 **같은 이 함수**를 본다 —
    /// 두 곳이 각자 판정하면 "사이드바에서는 꺼낼 수 있는데 목록에서는 항목이 없다"가 된다.
    /// 부팅 볼륨은 여기 들어오지 않는다(`VolumeService.isEjectable` 참조).
    func isEjectableVolume(_ url: URL) -> Bool {
        ejectableVolumeKeys.contains(Self.indexKey(url))
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
            // 재사용 노드는 **반드시 새 섹션 노드에 다시 이어야 한다** (2026-08-18 회귀 수정).
            // 옛 섹션 노드는 이 rebuild에서 버려지므로, 재연결을 빠뜨리면 weak `parent`가
            // 곧바로 nil이 되어 `isVolumeRoot` 같은 부모 기반 판정이 조용히 무너진다.
            existing.reattach(to: parent)
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
