import AppKit
import XCTest
@testable import UniFinder

/// 백그라운드 실행자에서 호출될 수 있는 조회 훅의 호출 횟수를 안전하게 세는 프로브.
private final class LookupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func record(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count
    }
}

/// `IconProvider` 회귀 테스트 (code review 필수 수정 #3, #4).
@MainActor
final class IconProviderTests: TempDirectoryTestCase {

    private func item(
        _ name: String,
        isDirectory: Bool = false,
        isSymlink: Bool = false
    ) -> FileItem {
        let url = testRoot.appendingPathComponent(name, isDirectory: isDirectory)
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isHidden: false,
            isSymlink: isSymlink,
            size: 0,
            modifiedAt: Fixture.fixedDate(),
            typeDescription: "Data"
        )
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeProvider(probe: LookupProbe? = nil) -> IconProvider {
        IconProvider { path in
            probe?.record(path)
            return NSImage(size: NSSize(width: 32, height: 32))
        }
    }

    // MARK: - #3 캐시 키 충돌

    /// **재현 시나리오**: 확장자 없는 심볼릭 링크(`~/bin/tool -> ...`)와 확장자 없는 일반 파일
    /// (`README`)이 `"file:noext"` 키를 공유해, 링크에 배지 없는 아이콘이 표시되거나
    /// 반대로 일반 파일에 링크 배지가 붙었다.
    func testCacheKey_noExtension_symlinkAndPlainFileDoNotCollide() {
        let plain = item("README")
        let link = item("tool", isSymlink: true)

        XCTAssertNotEqual(
            IconProvider.cacheKey(for: plain),
            IconProvider.cacheKey(for: link),
            "확장자 없는 파일과 확장자 없는 심볼릭 링크가 같은 캐시 키를 공유하면 배지가 뒤섞인다"
        )
    }

    func testCacheKey_withExtension_symlinkAndPlainFileDoNotCollide() {
        XCTAssertNotEqual(
            IconProvider.cacheKey(for: item("a.txt")),
            IconProvider.cacheKey(for: item("b.txt", isSymlink: true))
        )
    }

    func testCacheKey_sameKindGroupsShareKey() {
        // 같은 확장자·같은 심볼릭 여부는 계속 하나의 키로 묶여야 한다(10만 항목 캐시 효율).
        XCTAssertEqual(IconProvider.cacheKey(for: item("a.txt")), IconProvider.cacheKey(for: item("b.txt")))
        XCTAssertEqual(IconProvider.cacheKey(for: item("README")), IconProvider.cacheKey(for: item("LICENSE")))
    }

    func testIcon_noExtensionSymlink_doesNotReusePlainFileCacheEntry() async {
        let provider = makeProvider()
        let plain = item("README")
        let link = item("tool", isSymlink: true)

        provider.icon(for: plain) { _ in }
        await waitUntil { provider.cachedIcon(for: plain) != nil }
        XCTAssertNotNil(provider.cachedIcon(for: plain))

        XCTAssertNil(
            provider.cachedIcon(for: link),
            "확장자 없는 심볼릭 링크가 일반 파일의 캐시 엔트리를 그대로 받아가면 안 됨"
        )

        provider.icon(for: link) { _ in }
        await waitUntil { provider.cachedIcon(for: link) != nil }
        XCTAssertNotNil(provider.cachedIcon(for: link))
    }

    // MARK: - #4 NSImage 데이터 레이스

    /// **재현 시나리오**: `NSWorkspace.icon(forFile:)`이 돌려준 인스턴스를 그 자리에서
    /// `image.size = ...`로 변형했다. 이 API는 스레드 안전이 보장되지 않고 동일 파일/타입에
    /// 대해 공유 인스턴스를 돌려줄 수 있어, 여러 태스크가 동시에 같은 객체를 변형했다.
    func testDefaultLookup_returnsCopy_leavingSharedInstanceUntouched() throws {
        let file = try Fixture.makeFile(in: testRoot, name: "sample.dat")
        let shared = NSWorkspace.shared.icon(forFile: file.path)
        let originalSize = shared.size

        guard let copy = IconProvider.defaultLookup(file.path) else {
            return XCTFail("아이콘 조회 실패")
        }

        XCTAssertFalse(copy === shared, "조회 결과를 그대로 변형하면 공유 인스턴스에 데이터 레이스가 생긴다")

        copy.size = NSSize(width: 16, height: 16)
        XCTAssertEqual(shared.size, originalSize, "사본 변형이 공유 인스턴스에 영향을 주면 안 됨")
        XCTAssertEqual(NSWorkspace.shared.icon(forFile: file.path).size, originalSize)
    }

    // MARK: - #4 취소 전파

    /// **재현 시나리오**: 조회를 `Task.detached`로 띄우면 부모 취소를 상속하지 않아
    /// detached 태스크 안의 `guard !Task.isCancelled`가 항상 거짓으로 평가된다.
    /// 즉 스크롤로 셀이 재사용되어 `token.cancel()`을 불러도 이미 시작된 조회는 계속 수행됐다.
    func testIconRequest_cancelledBeforeStart_skipsLookupEntirely() async {
        let probe = LookupProbe()
        let provider = makeProvider(probe: probe)
        let target = item("heavy.dat")

        let token = provider.icon(for: target) { _ in
            XCTFail("취소된 요청의 completion이 호출되면 안 됨")
        }
        XCTAssertNotNil(token, "캐시 미스이므로 토큰이 반환되어야 함")

        token?.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(probe.count, 0, "취소가 전파되지 않으면 조회 작업이 그대로 수행된다(Task.detached 회귀)")
        XCTAssertNil(provider.cachedIcon(for: target), "취소된 요청의 결과가 캐시에 들어가면 안 됨")
    }

    func testIconRequest_notCancelled_performsLookupAndCaches() async {
        let probe = LookupProbe()
        let provider = makeProvider(probe: probe)
        let target = item("normal.dat")

        provider.icon(for: target) { _ in }
        await waitUntil { provider.cachedIcon(for: target) != nil }

        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(provider.cachedIcon(for: target)?.size, NSSize(width: 16, height: 16))
    }

    func testIcon_cacheHit_returnsSynchronouslyWithoutToken() async {
        let provider = makeProvider()
        let target = item("cached.dat")

        provider.icon(for: target) { _ in }
        await waitUntil { provider.cachedIcon(for: target) != nil }

        var delivered: NSImage?
        let token = provider.icon(for: target) { image in delivered = image }
        XCTAssertNil(token, "캐시 히트는 토큰 없이 즉시 반환되어야 함")
        XCTAssertNotNil(delivered)
    }
}
