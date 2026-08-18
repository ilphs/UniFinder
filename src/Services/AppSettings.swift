import Foundation
import Observation

/// `UserDefaults` 기반 영속 설정 (UI설계 §1 상태 저장).
/// M1 범위: 숨김 표시 여부, 정렬 기준/방향, 사이드바 폭, 컬럼 폭.
/// 2026-08-18 추가: 즐겨찾기 목록(설계서 §2.2 — MVP 고정 3개에서 편집 가능으로 확장).
@Observable
@MainActor
final class AppSettings {

    private enum Key {
        static let showHidden = "showHiddenItems"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let sidebarWidth = "sidebarWidth"
        static let columnWidthPrefix = "columnWidth."
        static let favoritePaths = "favoritePaths"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: Key.showHidden) }
    }

    var sortDescriptor: FileSortDescriptor {
        didSet {
            defaults.set(sortDescriptor.key.rawValue, forKey: Key.sortKey)
            defaults.set(sortDescriptor.ascending, forKey: Key.sortAscending)
        }
    }

    var sidebarWidth: Double {
        didSet { defaults.set(sidebarWidth, forKey: Key.sidebarWidth) }
    }

    /// 즐겨찾기 폴더 경로 (표기 보존 — `PathKey.exactPath` 기준).
    ///
    /// **비샌드박스 앱**이라(`src/App/UniFinder.entitlements`의 `app-sandbox: false`)
    /// security-scoped bookmark 없이 경로 문자열만으로 다음 실행에서도 그대로 접근된다.
    /// 순서는 사용자가 등록한 순서를 유지한다(트리 표시 순서 = 이 배열 순서).
    ///
    /// 외부에서 직접 갈아끼우지 못하게 `private(set)`으로 두고 `addFavorite`/`removeFavorite`만
    /// 노출한다 — 중복 판정을 `PathKey` 한 곳으로 모으기 위함이다(문자열 단순 비교 금지).
    private(set) var favoritePaths: [String] {
        didSet { defaults.set(favoritePaths, forKey: Key.favoritePaths) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showHidden = defaults.bool(forKey: Key.showHidden)

        let key = SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .name
        let ascending = defaults.object(forKey: Key.sortAscending) as? Bool ?? true
        self.sortDescriptor = FileSortDescriptor(key: key, ascending: ascending)

        let width = defaults.double(forKey: Key.sidebarWidth)
        self.sidebarWidth = (width >= 180 && width <= 400) ? width : 240

        // **키 부재와 빈 배열은 다른 상태다.** 최초 실행(키 부재)에만 기본 3개를 시딩하고,
        // 사용자가 전부 지운 상태(빈 배열)는 그대로 존중한다 — 아니면 다음 실행마다 되살아난다.
        if let stored = defaults.array(forKey: Key.favoritePaths) as? [String] {
            self.favoritePaths = Self.deduplicated(stored)
        } else {
            let seeded = Self.seedFavoritePaths()
            self.favoritePaths = seeded
            // `didSet`은 init 대입에서 돌지 않으므로 여기서 직접 기록해 "키 부재" 상태를 끝낸다.
            defaults.set(seeded, forKey: Key.favoritePaths)
        }
    }

    // MARK: - 즐겨찾기 (2026-08-18)

    /// 저장 순서를 유지한 즐겨찾기 URL 목록. **존재 여부는 걸러내지 않는다** —
    /// 표시 단계(`TreeModel.rebuildSections`)에서만 거른다(유령 경로 정책은 그쪽 주석 참조).
    var favoriteURLs: [URL] {
        favoritePaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// 이미 즐겨찾기인지. 표기(후행 슬래시·대소문자) 차이를 흡수하는 `PathKey` 기준이다.
    func isFavorite(_ url: URL) -> Bool {
        let key = PathKey.key(url)
        return favoritePaths.contains { PathKey.key(URL(fileURLWithPath: $0)) == key }
    }

    /// - Returns: 실제로 추가됐으면 `true`. 이미 있으면 `false`(중복 등록 거부).
    @discardableResult
    func addFavorite(_ url: URL) -> Bool {
        guard !isFavorite(url) else { return false }
        favoritePaths.append(PathKey.exactPath(url))
        return true
    }

    /// - Returns: 실제로 제거됐으면 `true`.
    ///
    /// 파일시스템은 건드리지 않는다 — "즐겨찾기에서 제거"는 삭제와 **다른 개념**이다.
    @discardableResult
    func removeFavorite(_ url: URL) -> Bool {
        let key = PathKey.key(url)
        let filtered = favoritePaths.filter { PathKey.key(URL(fileURLWithPath: $0)) != key }
        guard filtered.count != favoritePaths.count else { return false }
        favoritePaths = filtered
        return true
    }

    /// 최초 실행 시딩 값 — 기존 하드코딩과 같은 데스크탑/다운로드/문서.
    /// (`TreeModel.favoriteURLs()`가 매번 계산하던 것을 저장소로 옮긴 것뿐이라 동작이 바뀌지 않는다)
    private static func seedFavoritePaths() -> [String] {
        let fileManager = FileManager.default
        let candidates: [FileManager.SearchPathDirectory] = [.desktopDirectory, .downloadsDirectory, .documentDirectory]
        return deduplicated(
            candidates.compactMap { directory in
                fileManager.urls(for: directory, in: .userDomainMask).first.map(PathKey.exactPath)
            }
        )
    }

    /// 저장된 값에 중복이 섞여 있어도(수동 편집·이전 버전 잔재) 트리에 같은 항목이 두 번 뜨지 않게 한다.
    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard !path.isEmpty else { return nil }
            let exact = PathKey.exactPath(URL(fileURLWithPath: path))
            return seen.insert(PathKey.key(URL(fileURLWithPath: exact))).inserted ? exact : nil
        }
    }

    // MARK: - 컬럼 폭

    func columnWidth(for key: SortKey) -> Double? {
        let stored = defaults.double(forKey: Key.columnWidthPrefix + key.rawValue)
        return stored > 0 ? stored : nil
    }

    func setColumnWidth(_ width: Double, for key: SortKey) {
        defaults.set(width, forKey: Key.columnWidthPrefix + key.rawValue)
    }
}
