import XCTest
@testable import UniFinder

/// `PathKey` — 경로 비교의 단일 기준 (M2 리뷰 blocker 근본 원인).
///
/// macOS 기본 볼륨(APFS)은 대소문자 **비구분**이다. 키가 대소문자를 정규화하지 않으면
/// 표기만 다른 두 경로(`/a/Desktop` vs `/a/desktop`)가 "다른 항목"으로 오판되고,
/// 그 오판이 `FileOperations`의 "같은 폴더" 판정 → 덮어쓰기 → **원본 삭제**로 이어진다.
///
/// 동시에, 키로 URL을 다시 만드는 자리(`parent`/`directoryURL`)에서 소문자 키를 쓰면
/// 실제 경로가 뭉개진다. 그래서 "비교용 키"와 "표기 보존 경로"를 분리해 두 성질을 모두 고정한다.
final class PathKeyTests: XCTestCase {

    // MARK: - 대소문자 정규화 (동일성 비교)

    func testKey_normalizesCase_soCaseInsensitiveVolumePathsCompareEqual() {
        let upper = URL(fileURLWithPath: "/Users/Admin/Desktop")
        let lower = URL(fileURLWithPath: "/users/admin/desktop")

        XCTAssertEqual(PathKey.key(upper), PathKey.key(lower))
        XCTAssertTrue(
            PathKey.isSame(upper, lower),
            "대소문자만 다른 경로를 다른 항목으로 보면 덮어쓰기 대상==원본을 놓친다(blocker 근본 원인)"
        )
    }

    func testKey_stillStripsTrailingSlash() {
        let withSlash = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        let withoutSlash = URL(fileURLWithPath: "/tmp/folder", isDirectory: false)

        XCTAssertEqual(PathKey.key(withSlash), PathKey.key(withoutSlash))
        XCTAssertFalse(PathKey.key(withSlash).hasSuffix("/"))
    }

    func testIsSameOrDescendant_ignoresCase() {
        let base = URL(fileURLWithPath: "/Users/Admin/Documents")
        let child = URL(fileURLWithPath: "/users/admin/documents/report.txt")

        XCTAssertTrue(
            PathKey.isSameOrDescendant(child, of: base),
            "대소문자 비구분 볼륨에서는 표기가 달라도 하위 경로다 — 자기 하위로의 복사/이동을 막아야 한다"
        )
    }

    func testIsSameOrDescendant_doesNotMatchSiblingWithSharedPrefix() {
        let base = URL(fileURLWithPath: "/tmp/folder")
        let sibling = URL(fileURLWithPath: "/tmp/folder2/file.txt")

        XCTAssertFalse(PathKey.isSameOrDescendant(sibling, of: base), "접두어만 같은 형제 경로를 하위로 보면 안 된다")
    }

    // MARK: - 표기 보존 (URL 재구성 / 변화 판정)

    func testExactPath_preservesCase() {
        let url = URL(fileURLWithPath: "/Users/Admin/Desktop")

        XCTAssertEqual(PathKey.exactPath(url), "/Users/Admin/Desktop")
        XCTAssertFalse(PathKey.isSameExactPath(url, URL(fileURLWithPath: "/users/admin/desktop")))
    }

    func testParent_preservesCase_soReconstructedURLStillExists() {
        let url = URL(fileURLWithPath: "/Users/Admin/Desktop/file.txt")

        let parent = PathKey.parent(of: url)

        XCTAssertEqual(
            parent?.path, "/Users/Admin/Desktop",
            "키로 URL을 다시 만들면서 소문자로 뭉개면 대소문자 구분 볼륨에서 존재하지 않는 경로가 된다"
        )
    }

    func testParent_atRoot_isNil() {
        XCTAssertNil(PathKey.parent(of: URL(fileURLWithPath: "/")))
    }

    func testDirectoryURL_preservesCaseAndMarksDirectory() {
        let url = PathKey.directoryURL(URL(fileURLWithPath: "/Users/Admin/Desktop"))

        XCTAssertEqual(url.path, "/Users/Admin/Desktop")
        XCTAssertTrue(url.absoluteString.hasSuffix("/"), "폴더 표기(후행 슬래시)로 통일되어야 함")
    }
}
