import AppKit

/// 볼륨 노드용 아이콘 캐시 (2026-08-18 C단계).
///
/// **왜 별도 캐시인가**: `NSWorkspace.icon(forFile:)`는 디스크를 친다. 트리 셀은 스크롤할 때마다
/// `viewFor`에서 다시 그려지므로 매번 호출하면 스크롤이 끊긴다.
///
/// **왜 `IconProvider`를 쓰지 않는가**: `IconProvider`는 `FileItem`(목록 항목) 단위로 키를 만들고
/// 캐시 미스를 **비동기**로 채운다 — 목록의 수만 개 항목을 스크롤하며 채우기 위한 설계다.
/// 볼륨은 보통 1~3개뿐이고 트리 셀은 그리는 즉시 최종 이미지가 필요하므로, 여기서는
/// **동기 조회 + 작은 사전**이 더 단순하고 예측 가능하다. 대신 무효화 시점을 명시적으로 갖는다.
///
/// **무효화**: 볼륨 이름 변경(`didRenameVolumeNotification`)·마운트·언마운트는 전부
/// `TreeModel.rebuildSections()`를 거치고 `sectionsRevision`을 올린다. 브릿지는 그 카운터가
/// 바뀔 때만 `invalidate()`를 호출한다 — `revision`(노드 확장마다 증가)에 묶으면 스크롤 도중
/// 캐시가 통째로 버려져 캐시가 있으나 마나가 된다.
@MainActor
final class VolumeIconCache {

    /// 경로 → 아이콘 조회 지점. 테스트가 다른 구현을 주입한다.
    /// `@Sendable`인 이유는 `IconProvider.Lookup`과 같다 — nonisolated 기본값을 두기 위함이다.
    typealias Lookup = @Sendable (String) -> NSImage?

    /// 기본 조회. **반드시 사본을 돌려준다** — `NSWorkspace`가 주는 공유 인스턴스를 그대로
    /// `size` 변형하면 AppKit의 다른 소비자에게도 사이드바 크기가 새어 나간다(`IconProvider`와 같은 규칙).
    nonisolated static let defaultLookup: Lookup = { path in
        NSWorkspace.shared.icon(forFile: path).copy() as? NSImage
    }

    private let lookup: Lookup

    /// `PathKey.key` 기준 캐시 — 표기(후행 슬래시·대소문자)가 달라도 같은 볼륨은 한 번만 조회한다.
    private var cache: [String: NSImage] = [:]

    /// 조회(캐시 미스)가 실제로 일어난 횟수. 캐시 히트 검증용이며 프로덕션에서는 읽지 않는다.
    private(set) var lookupCount = 0

    init(lookup: @escaping Lookup = VolumeIconCache.defaultLookup) {
        self.lookup = lookup
    }

    /// 캐시 히트면 즉시 반환, 미스면 조회 후 채운다.
    /// - Returns: 조회에 실패하면 `nil` (호출자가 공용 폴더 아이콘으로 되돌린다).
    func icon(for url: URL) -> NSImage? {
        let key = PathKey.key(url)
        if let cached = cache[key] { return cached }

        lookupCount += 1
        guard let image = lookup(PathKey.exactPath(url)) else { return nil }
        // 이 캐시의 유일한 소비자는 사이드바 트리 셀이다 — 셀 아이콘 프레임과 크기를 묶어 둔다.
        // 프레임보다 작으면 `.scaleProportionallyDown`이 확대하지 않아 볼륨만 작게 뜬다.
        image.size = NSSize(width: SidebarMetrics.nodeIconLength, height: SidebarMetrics.nodeIconLength)
        cache[key] = image
        return image
    }

    /// 볼륨 구성/이름이 바뀌었을 때만 호출한다.
    func invalidate() {
        cache.removeAll()
    }

    var count: Int { cache.count }
}
