import AppKit
import XCTest
@testable import UniFinder

/// M3 T3 — 드롭 **판정 규칙** (m3-impl B10·B13). ralph 작성.
///
/// 실행 경로의 안전성은 `AppModelDropTests`(서비스 가드 관통)가 담당하고, 여기서는 그 앞단인
/// UI 판정만 다룬다: 이동/복사 기본값, 수식키, 볼륨 동일성, 사전 거부 범위.
final class DragDropPolicyTests: TempDirectoryTestCase {

    // MARK: - B13: 이동/복사 기본값 + 수식키
    //
    // 이 절의 대상인 `operation(modifiers:isSameVolume:)`은 M3 리뷰 선택 5로 **deprecated**가 됐다
    // (프로덕션 호출자 없음 — blocker 1이 금지한 `NSEvent.modifierFlags`를 입력으로 받기 때문).
    // 규칙 자체는 사라지지 않았으므로 테스트는 그대로 두되, 각 케이스를 deprecated 컨텍스트로 표시해
    // **테스트 빌드의 경고 0을 유지**한다(deprecated 안에서의 호출은 경고 대상이 아니다).
    // 지금 유효한 판정 입력은 `operation(sourceMask:isSameVolume:)`이며 M3DropOperationMaskTests가 덮는다.

    @available(*, deprecated, message: "deprecated API의 규칙을 고정하는 보관용 케이스")
    func testOperation_sameVolumeWithoutModifiers_defaultsToMove() {
        XCTAssertEqual(DragDropPolicy.operation(modifiers: [], isSameVolume: true), .move)
    }

    @available(*, deprecated, message: "deprecated API의 규칙을 고정하는 보관용 케이스")
    func testOperation_differentVolumeWithoutModifiers_defaultsToCopy() {
        XCTAssertEqual(
            DragDropPolicy.operation(modifiers: [], isSameVolume: false),
            .copy,
            "다른 볼륨으로의 드롭 기본값은 복사다(Win10·Finder 공통 관례)"
        )
    }

    @available(*, deprecated, message: "deprecated API의 규칙을 고정하는 보관용 케이스")
    func testOperation_optionForcesCopy_evenOnSameVolume() {
        XCTAssertEqual(DragDropPolicy.operation(modifiers: [.option], isSameVolume: true), .copy)
    }

    @available(*, deprecated, message: "deprecated API의 규칙을 고정하는 보관용 케이스")
    func testOperation_commandForcesMove_evenAcrossVolumes() {
        XCTAssertEqual(DragDropPolicy.operation(modifiers: [.command], isSameVolume: false), .move)
    }

    /// 모호한 입력(둘 다 누름)에서는 비파괴 쪽으로 기운다 — 되돌림 수단이 휴지통 복원뿐이다(B13).
    @available(*, deprecated, message: "deprecated API의 규칙을 고정하는 보관용 케이스")
    func testOperation_optionAndCommandTogether_prefersCopy() {
        XCTAssertEqual(DragDropPolicy.operation(modifiers: [.option, .command], isSameVolume: true), .copy)
    }

    /// M2에서 확립한 합성 플래그 제거 규칙이 드래그 판정에도 적용되는지.
    /// (Caps Lock이 켜져 있다고 이동이 복사로 바뀌면 안 된다)
    @available(*, deprecated, message: "deprecated API의 규칙을 고정하는 보관용 케이스")
    func testOperation_syntheticFlagsAreIgnored() {
        XCTAssertEqual(
            DragDropPolicy.operation(modifiers: [.capsLock, .function, .numericPad], isSameVolume: true),
            .move,
            "Caps Lock 등 합성 플래그가 드롭 동작을 바꾸면 안 된다(M2 리뷰 major와 같은 뿌리)"
        )
    }

    // MARK: - B13: 볼륨 동일성은 경로 접두사가 아니라 volumeIdentifier

    func testIsSameVolume_forTwoPathsOnTheSameVolume_isTrue() throws {
        let a = try Fixture.makeDirectory(in: testRoot, name: "a")
        let b = try Fixture.makeDirectory(in: testRoot, name: "b")

        XCTAssertTrue(DragDropPolicy.isSameVolume(a, b))
    }

    /// 심볼릭 링크 별칭 경로는 문자열이 전혀 다르지만 **같은 볼륨**이다 —
    /// 경로 접두사로 판정했다면 여기서 "다른 볼륨 = 복사"로 오판한다.
    func testIsSameVolume_throughAliasPath_isStillTrue() throws {
        let real = try Fixture.makeDirectory(in: testRoot, name: "real")
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: real)

        XCTAssertTrue(
            DragDropPolicy.isSameVolume(testRoot, alias),
            "별칭 경로를 다른 볼륨으로 오판하면 같은 볼륨 드롭이 복사로 바뀐다(B13)"
        )
    }

    /// 아직 존재하지 않는 대상 경로(드롭 결과)도 존재하는 조상까지 올라가 판정해야 한다.
    func testIsSameVolume_forNotYetExistingDestination_usesNearestExistingAncestor() {
        let future = testRoot.appendingPathComponent("not-created-yet/child", isDirectory: true)

        XCTAssertTrue(DragDropPolicy.isSameVolume(testRoot, future))
    }

    // MARK: - B10: UI 레벨 사전 거부 범위

    func testCanAcceptDrop_intoOwnSubdirectory_isRejected() throws {
        let source = try Fixture.makeDirectory(in: testRoot, name: "source")
        let sub = try Fixture.makeDirectory(in: source, name: "sub")

        XCTAssertFalse(DragDropPolicy.canAcceptDrop(urls: [source], into: sub))
    }

    func testCanAcceptDrop_intoItself_isRejected() throws {
        let source = try Fixture.makeDirectory(in: testRoot, name: "source")

        XCTAssertFalse(DragDropPolicy.canAcceptDrop(urls: [source], into: source))
    }

    /// 별칭 경로로 자기 하위를 가리킨 경우 — 문자열 접두사가 겹치지 않아 UI 판정도 2축이어야 한다.
    func testCanAcceptDrop_intoOwnDescendantThroughAliasPath_isRejected() throws {
        let source = try Fixture.makeDirectory(in: testRoot, name: "source")
        let sub = try Fixture.makeDirectory(in: source, name: "sub")
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: sub)
        XCTAssertFalse(
            PathKey.isSameOrDescendant(alias, of: source),
            "별칭 경로가 문자열로 포함 관계를 드러내면 이 테스트는 무의미하다"
        )

        XCTAssertFalse(
            DragDropPolicy.canAcceptDrop(urls: [source], into: alias),
            "별칭 경로 경유 자기 하위 드롭은 커서 단계에서도 거부되어야 한다(B1 회귀)"
        )
    }

    /// **같은 폴더 드롭은 거부하지 않는다** — 이동이면 no-op, 복사면 자동 넘버링이라는
    /// 정의된 동작이 있다(UI설계 §7.1). 여기서 막으면 "같은 폴더에 사본 만들기"가 불가능해진다.
    func testCanAcceptDrop_intoOwnParentFolder_isAllowed() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")
        let file = try Fixture.makeFile(in: folder, name: "note.txt")

        XCTAssertTrue(DragDropPolicy.canAcceptDrop(urls: [file], into: folder))
    }

    func testCanAcceptDrop_emptyURLs_isRejected() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "folder")

        XCTAssertFalse(DragDropPolicy.canAcceptDrop(urls: [], into: folder))
    }

    /// 여러 항목 중 하나라도 위험하면 드롭 전체를 거부한다(부분 수행보다 명확한 거부).
    func testCanAcceptDrop_mixedSafeAndUnsafeSources_isRejected() throws {
        let source = try Fixture.makeDirectory(in: testRoot, name: "source")
        let sub = try Fixture.makeDirectory(in: source, name: "sub")
        let safe = try Fixture.makeFile(in: testRoot, name: "safe.txt")

        XCTAssertFalse(DragDropPolicy.canAcceptDrop(urls: [safe, source], into: sub))
    }

    // MARK: - 파스트보드 → 파일 URL

    func testFileURLs_readsFileURLsFromPasteboard() throws {
        let file = try Fixture.makeFile(in: testRoot, name: "dragged.txt")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DragDropPolicyTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])

        let urls = DragDropPolicy.fileURLs(from: pasteboard)

        XCTAssertEqual(urls.map(PathKey.key), [PathKey.key(file)])
    }

    func testFileURLs_ignoresNonFileContent() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DragDropPolicyTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)

        XCTAssertTrue(DragDropPolicy.fileURLs(from: pasteboard).isEmpty)
    }

    func testDraggingOperation_mapsKindToCursorBadge() {
        XCTAssertEqual(DragDropPolicy.draggingOperation(for: .move), .move)
        XCTAssertEqual(DragDropPolicy.draggingOperation(for: .copy), .copy)
    }
}
