import Foundation

/// 우측 목록의 정렬 기준 컬럼.
enum SortKey: String, CaseIterable, Sendable, Codable {
    case name
    case date
    case kind
    case size

    /// `NSTableColumn.identifier`와 1:1로 대응한다.
    var columnIdentifier: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .name: return "이름"
        case .date: return "수정일"
        case .kind: return "종류"
        case .size: return "크기"
        }
    }
}

/// 정렬 기준 + 방향. 폴더 우선 규칙은 방향과 무관하게 항상 적용된다(설계서 §2.3).
struct FileSortDescriptor: Sendable, Equatable, Codable {
    var key: SortKey
    var ascending: Bool

    init(key: SortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    static let `default` = FileSortDescriptor(key: .name, ascending: true)

    /// 헤더 클릭 시의 토글 규칙: 같은 컬럼이면 방향 반전, 다른 컬럼이면 오름차순으로 시작.
    func toggled(for key: SortKey) -> FileSortDescriptor {
        if self.key == key {
            return FileSortDescriptor(key: key, ascending: !ascending)
        }
        return FileSortDescriptor(key: key, ascending: true)
    }
}

extension Array where Element == FileItem {

    /// 폴더 우선 + 지정 기준 정렬. 이름 비교는 Finder와 동일하게 `localizedStandardCompare`.
    ///
    /// 100k 항목에서도 결정적 순서를 보장하기 위해, 1차 기준이 같으면 이름 → 경로 순으로
    /// tie-break 한다(안정 정렬에 의존하지 않는다).
    func sorted(by descriptor: FileSortDescriptor) -> [FileItem] {
        sorted { lhs, rhs in
            FileSorting.areInIncreasingOrder(lhs, rhs, descriptor: descriptor)
        }
    }
}

/// 정렬 비교 로직(순수 함수). 백그라운드에서 호출 가능하도록 `FileItem`만 다룬다.
enum FileSorting {

    static func areInIncreasingOrder(
        _ lhs: FileItem,
        _ rhs: FileItem,
        descriptor: FileSortDescriptor
    ) -> Bool {
        // 폴더는 정렬 방향과 무관하게 항상 파일보다 위 (Win10 기본 동작)
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }

        let primary = compare(lhs, rhs, key: descriptor.key)
        if primary != .orderedSame {
            return descriptor.ascending
                ? primary == .orderedAscending
                : primary == .orderedDescending
        }

        let byName = lhs.name.localizedStandardCompare(rhs.name)
        if byName != .orderedSame {
            return descriptor.ascending
                ? byName == .orderedAscending
                : byName == .orderedDescending
        }

        // 완전 동률: 경로로 결정적 순서를 강제
        return descriptor.ascending
            ? lhs.url.path < rhs.url.path
            : lhs.url.path > rhs.url.path
    }

    private static func compare(
        _ lhs: FileItem,
        _ rhs: FileItem,
        key: SortKey
    ) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)

        case .date:
            let l = lhs.modifiedAt ?? .distantPast
            let r = rhs.modifiedAt ?? .distantPast
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending

        case .kind:
            return lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)

        case .size:
            let l = lhs.size ?? -1
            let r = rhs.size ?? -1
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        }
    }
}
