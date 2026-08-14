import Foundation
import Observation

/// `UserDefaults` 기반 영속 설정 (UI설계 §1 상태 저장).
/// M1 범위: 숨김 표시 여부, 정렬 기준/방향, 사이드바 폭, 컬럼 폭.
@Observable
@MainActor
final class AppSettings {

    private enum Key {
        static let showHidden = "showHiddenItems"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let sidebarWidth = "sidebarWidth"
        static let columnWidthPrefix = "columnWidth."
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showHidden = defaults.bool(forKey: Key.showHidden)

        let key = SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .name
        let ascending = defaults.object(forKey: Key.sortAscending) as? Bool ?? true
        self.sortDescriptor = FileSortDescriptor(key: key, ascending: ascending)

        let width = defaults.double(forKey: Key.sidebarWidth)
        self.sidebarWidth = (width >= 180 && width <= 400) ? width : 240
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
