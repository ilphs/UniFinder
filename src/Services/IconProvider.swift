import AppKit
import UniformTypeIdentifiers

/// 아이콘 요청 핸들. 셀이 재사용되면 이전 요청을 취소해 스크롤 중 불필요한 작업을 막는다.
@MainActor
final class IconRequestToken {
    fileprivate var task: Task<Void, Never>?
    fileprivate init() {}

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// `NSWorkspace` 아이콘 캐시 (설계 결정 #5 / architect B2).
///
/// **actor가 아니라 `@MainActor` 클래스다.** `NSWorkspace.icon(forFile:)`이 돌려주는
/// `NSImage`는 `Sendable`이 아니므로 actor 경계를 넘길 수 없다. 대신
/// - 캐시 히트는 동기로 즉시 반환하고(스크롤 중 대부분이 여기서 끝난다),
/// - 미스일 때만 백그라운드에서 아이콘을 만들어 `MainActor`로 복귀해 캐시를 채운다.
///
/// 백그라운드에서 만든 `NSImage`를 MainActor로 옮기기 위한 유일한 지점이
/// `IconBox`이며, 이 이미지는 생성 직후 다른 스레드에서 건드리지 않으므로
/// `@unchecked Sendable`로 한정한다.
@MainActor
final class IconProvider {

    /// 경로 → 아이콘 조회 지점. **반드시 새 인스턴스(복사본)를 돌려줘야 한다.**
    ///
    /// `NSWorkspace.icon(forFile:)`은 스레드 안전성이 보장되지 않고 같은 파일/타입에 대해
    /// 공유 인스턴스를 돌려줄 수 있다. 그 인스턴스를 그대로 `size` 변형하면 여러 태스크가
    /// 동시에 같은 객체를 변형하는 데이터 레이스가 되고, AppKit의 다른 소비자에게도 16x16이
    /// 새어 나간다. 그래서 조회 직후 `copy()`한 사본만 밖으로 내보낸다.
    typealias Lookup = @Sendable (String) -> NSImage?

    static let shared = IconProvider()

    nonisolated static let defaultLookup: Lookup = { path in
        NSWorkspace.shared.icon(forFile: path).copy() as? NSImage
    }

    /// 백그라운드 → MainActor 이동용 1회성 상자 (B2의 유일한 Sendable 예외 지점).
    private struct IconBox: @unchecked Sendable {
        let image: NSImage
    }

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()

    private let lookup: Lookup

    init(lookup: @escaping Lookup = IconProvider.defaultLookup) {
        self.lookup = lookup
    }

    // MARK: - 조회

    /// 캐시에 있으면 즉시 반환. 없으면 `nil` (호출자는 placeholder를 먼저 그린다).
    func cachedIcon(for item: FileItem) -> NSImage? {
        cache.object(forKey: Self.cacheKey(for: item) as NSString)
    }

    /// 종류별 기본 아이콘(폴더/일반 파일). 캐시 미스 시 즉시 그릴 placeholder 용도로 쓴다.
    func placeholderIcon(for item: FileItem) -> NSImage {
        let type: UTType = item.isDirectory ? .folder : .item
        let key = "placeholder:\(type.identifier)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        // 공유 인스턴스를 그대로 변형하지 않도록 사본을 만들어 캐시한다.
        let source = NSWorkspace.shared.icon(for: type)
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 16, height: 16)
        cache.setObject(image, forKey: key)
        return image
    }

    /// 캐시 히트면 동기 반환 후 `completion`을 호출하지 않는다.
    /// 미스면 백그라운드에서 아이콘을 만들고 MainActor에서 `completion`을 호출한다.
    @discardableResult
    func icon(for item: FileItem, completion: @escaping @MainActor (NSImage) -> Void) -> IconRequestToken? {
        let key = Self.cacheKey(for: item)
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return nil
        }

        let path = item.url.path
        let isSymlink = item.isSymlink
        let lookup = self.lookup
        let token = IconRequestToken()

        // `Task.detached`를 쓰면 부모 취소를 상속하지 않아 `token.cancel()`이 이미 시작된 조회를
        // 전혀 멈추지 못한다(안쪽 `Task.isCancelled`는 항상 false). 취소가 실제로 전파되도록
        // 구조적 자식 태스크(nonisolated async 함수)로 조회를 수행한다.
        token.task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let box = await Self.makeIcon(path: path, lookup: lookup)

            guard !Task.isCancelled, let self, let box else { return }
            let final = isSymlink ? Self.badgedSymlinkIcon(box.image) : box.image
            self.cache.setObject(final, forKey: key as NSString)
            completion(final)
        }
        return token
    }

    /// 아이콘 조회 + 크기 조정. MainActor 격리를 벗어난 실행자에서 수행되지만
    /// `lookup`이 돌려준 **사본**만 다루므로 공유 인스턴스를 변형하지 않는다.
    private nonisolated static func makeIcon(path: String, lookup: Lookup) async -> IconBox? {
        guard !Task.isCancelled else { return nil }
        guard let image = lookup(path) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return IconBox(image: image)
    }

    // MARK: - 캐시 키

    /// 앱 번들·폴더는 개별 아이콘이 다를 수 있어 경로로, 그 외 일반 파일은 확장자로 묶는다.
    /// (10만 항목 폴더에서 동일 확장자 아이콘을 반복 생성하지 않기 위함)
    ///
    /// 심볼릭 링크는 배지가 합성된 별도 이미지이므로 확장자 유무와 무관하게 키를 분리한다.
    /// (`internal` — 키 충돌 회귀 테스트에서 직접 검증한다)
    static func cacheKey(for item: FileItem) -> String {
        if item.isDirectory {
            return "dir:\(item.url.path)"
        }
        let ext = item.url.pathExtension.lowercased()
        if ext.isEmpty {
            return "file:noext\(item.isSymlink ? ":link" : "")"
        }
        if ext == "app" || ext == "framework" || ext == "bundle" {
            return "bundle:\(item.url.path)"
        }
        return "ext:\(ext)\(item.isSymlink ? ":link" : "")"
    }

    // MARK: - 심볼릭 링크 배지 (UI설계 §4.2)

    private static func badgedSymlinkIcon(_ base: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let badged = NSImage(size: size)
        badged.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))

        if let arrow = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: "Symbolic link") {
            let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
            let symbol = arrow.withSymbolConfiguration(config) ?? arrow
            let badgeRect = NSRect(x: 0, y: 0, width: 8, height: 8)

            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            symbol.draw(in: badgeRect.insetBy(dx: 1, dy: 1))
        }

        badged.unlockFocus()
        return badged
    }
}
