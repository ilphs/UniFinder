import XCTest
@testable import UniFinder

/// **데이터 손실 방지** 회귀 테스트 (M2 코드 리뷰 blocker 2건).
///
/// 두 blocker 모두 "고쳤을 것 같다"가 아니라 *조작 후에도 원본/보호 대상이 디스크에 그대로 있는가*로
/// 증명한다. 그래서 모든 케이스가 마지막에 파일 내용까지 확인한다.
///
/// 1. 덮어쓰기 대상이 사실은 원본 자신인 경우 (`/a/Desktop` vs `/a/desktop`, 심볼릭 링크 별칭)
///    → 예전 코드는 원본을 휴지통으로 보낸 뒤 `.sourceMissing`으로 실패했다.
/// 2. `move`의 원본 / `.replace`의 덮어쓰기 대상에 보호 대상 가드가 없던 문제
///    → 홈 루트·볼륨 루트가 이동/휴지통행이 될 수 있었다.
///
/// **테스트 안전성**: 실제 홈 디렉터리를 대상으로 하면 가드가 깨졌을 때 테스트가 사용자 홈을
/// 옮기거나 지운다. `FileOperations(homeDirectory:)`로 임시 폴더를 홈으로 주입해 같은 코드 경로를
/// 임시 디렉터리 안에서만 검증한다(테스트계획서 §1 원칙 1 — 파괴적 작업 격리).
final class FileOperationsSafetyTests: TempDirectoryTestCase {

    private func resolver(_ decisions: [ConflictDecision] = [], fallback: ConflictDecision = .skip) -> MockConflictResolver {
        MockConflictResolver(scripted: decisions, fallback: fallback)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 이 볼륨이 대소문자 **비구분**인지 (macOS 기본 APFS는 비구분).
    private func isCaseInsensitiveVolume(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
              let caseSensitive = values.volumeSupportsCaseSensitiveNames
        else { return false }
        return !caseSensitive
    }

    // MARK: - Blocker 1: 덮어쓰기 대상이 원본 자신

    /// 대상 폴더 안의 항목이 **하드 링크로 원본과 같은 파일**인 경우.
    /// 경로 문자열도 다르고 부모 폴더도 다르므로, 항목 식별자 비교만이 "대상==원본"을 잡을 수 있다.
    ///
    /// (예전에는 "원본의 부모를 가리키는 별칭 폴더에 복사"로 이 경로를 재현했지만, M2 백로그 B2
    ///  수정 이후 그 시나리오는 **같은 폴더 규칙**으로 먼저 흡수된다 — 아래 B2 절 참조.
    ///  `destinationIsSource` 가드 자체의 커버리지는 여기서 유지한다.)
    func testCopy_replaceWhenTargetIsHardLinkToSourceItself_isRejectedAndKeepsOriginal() async throws {
        let real = try Fixture.makeDirectory(in: testRoot, name: "real")
        let file = try Fixture.makeFile(in: real, name: "note.txt")
        try "ORIGINAL".write(to: file, atomically: true, encoding: .utf8)
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        // 대상 폴더에 원본과 같은 이름·같은 실체(inode)의 항목이 있다 → "덮어쓰기"가 곧 원본 조작.
        try FileManager.default.linkItem(at: file, to: destination.appendingPathComponent("note.txt"))

        let result = await FileOperations().copy(items: [file], to: destination, resolver: resolver([.replace]))

        XCTAssertEqual(result.failures.first?.error, .destinationIsSource, "대상==원본인 덮어쓰기가 거부되지 않음")
        XCTAssertTrue(result.produced.isEmpty)
        XCTAssertTrue(exists(file), "원본이 휴지통으로 사라졌다 — 데이터 손실(blocker 1)")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ORIGINAL", "원본 내용이 보존되어야 함")
    }

    func testMove_replaceWhenTargetIsHardLinkToSourceItself_isRejectedAndKeepsOriginal() async throws {
        let real = try Fixture.makeDirectory(in: testRoot, name: "real")
        let file = try Fixture.makeFile(in: real, name: "note.txt")
        try "ORIGINAL".write(to: file, atomically: true, encoding: .utf8)
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        try FileManager.default.linkItem(at: file, to: destination.appendingPathComponent("note.txt"))

        let result = await FileOperations().move(items: [file], to: destination, resolver: resolver([.replace]))

        XCTAssertEqual(result.failures.first?.error, .destinationIsSource)
        XCTAssertTrue(exists(file), "이동이 원본을 지우면 안 된다(blocker 1)")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ORIGINAL")
    }

    // MARK: - M2 백로그 B1: 자기 하위로의 복사/이동을 별칭 경로로 우회

    /// **M3 D&D 선처리**: 트리 노드는 심볼릭 링크를 그대로 보존하므로(`TreeNode.isSymlink`),
    /// "폴더 A를 A/sub를 가리키는 별칭 노드에 드롭"이 드래그 한 번으로 가능하다.
    /// `alias`(= `<root>/alias`)와 `source`(= `<root>/source`)는 문자열 접두사가 전혀 겹치지 않아
    /// `PathKey.isSameOrDescendant`만으로는 **무한 재귀 복사**를 그대로 통과시킨다.
    func testCopy_intoOwnDescendantReachedThroughAliasPath_isRejected() async throws {
        let source = try Fixture.makeDirectory(in: testRoot, name: "source")
        let sub = try Fixture.makeDirectory(in: source, name: "sub")
        let payload = try Fixture.makeFile(in: sub, name: "payload.txt")
        // 별칭 노드: <root>/alias -> <root>/source/sub
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: sub)
        XCTAssertFalse(
            PathKey.isSameOrDescendant(alias, of: source),
            "별칭 경로가 문자열로 포함 관계를 드러내면 이 테스트는 무의미하다"
        )

        let result = await FileOperations().copy(items: [source], to: alias, resolver: resolver())

        XCTAssertEqual(result.failures.first?.error, .destinationInsideSource, "별칭 경로로 자기 하위 복사 가드가 뚫렸다(B1)")
        XCTAssertTrue(result.produced.isEmpty)
        XCTAssertFalse(exists(sub.appendingPathComponent("source")), "무한 재귀 복사가 시작됐다(B1)")
        XCTAssertTrue(exists(payload), "원본 하위 항목이 그대로여야 함")
    }

    func testMove_intoOwnDescendantReachedThroughAliasPath_isRejected() async throws {
        let source = try Fixture.makeDirectory(in: testRoot, name: "source")
        let sub = try Fixture.makeDirectory(in: source, name: "sub")
        let payload = try Fixture.makeFile(in: sub, name: "payload.txt")
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: sub)

        let result = await FileOperations().move(items: [source], to: alias, resolver: resolver())

        XCTAssertEqual(result.failures.first?.error, .destinationInsideSource, "별칭 경로로 자기 하위 이동 가드가 뚫렸다(B1)")
        XCTAssertTrue(exists(source), "거부된 이동은 원본을 그대로 둬야 함")
        XCTAssertTrue(exists(payload))
        XCTAssertFalse(exists(sub.appendingPathComponent("source")))
    }

    /// 가드 과잉 확대 방지: 별칭이 **원본 밖**을 가리키면 정상 복사가 되어야 한다.
    func testCopy_intoAliasPointingOutsideSource_stillCopies() async throws {
        let source = try Fixture.makeDirectory(in: testRoot, name: "source")
        _ = try Fixture.makeFile(in: source, name: "payload.txt")
        let elsewhere = try Fixture.makeDirectory(in: testRoot, name: "elsewhere")
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: elsewhere)

        let result = await FileOperations().copy(items: [source], to: alias, resolver: resolver())

        XCTAssertTrue(result.failures.isEmpty, "원본과 무관한 별칭 대상 복사까지 막으면 안 됨: \(result.failures)")
        XCTAssertTrue(exists(elsewhere.appendingPathComponent("source/payload.txt")))
    }

    // MARK: - M2 백로그 B2: 별칭 경로로 도달한 "같은 폴더"

    /// 원본의 **부모 폴더**를 별칭 경로로 가리켜 붙여넣기/드롭한 경우.
    /// 문자열 비교만 하면 "다른 폴더"로 오판해 충돌 시트를 띄운다 — M3 D&D의
    /// "같은 폴더 드롭 = 무동작(copy는 자동 넘버링)" 수용 기준이 그대로 무너진다.
    func testCopy_intoOwnParentReachedThroughAliasPath_numbersCopyAndNeverAsks() async throws {
        let real = try Fixture.makeDirectory(in: testRoot, name: "real")
        let file = try Fixture.makeFile(in: real, name: "note.txt")
        try "ORIGINAL".write(to: file, atomically: true, encoding: .utf8)
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: real)
        XCTAssertFalse(PathKey.isSame(real, alias), "별칭 경로가 문자열로 같으면 이 테스트는 무의미하다")

        let mockResolver = resolver([.replace])
        let result = await FileOperations().copy(items: [file], to: alias, resolver: mockResolver)

        XCTAssertTrue(result.failures.isEmpty, "별칭 경로로 같은 폴더에 복사가 실패함: \(result.failures)")
        let askedCount = await mockResolver.seenConflicts.count
        XCTAssertEqual(askedCount, 0, "같은 폴더 복사는 충돌 질의 없이 넘버링되어야 함(UI설계 §7.1 / B2)")
        XCTAssertTrue(exists(file), "원본이 사라졌다 — 데이터 손실")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ORIGINAL")
        XCTAssertTrue(exists(real.appendingPathComponent("note 2.txt")), "\"둘 다 유지\" 넘버링 사본이 없음")
    }

    func testMove_intoOwnParentReachedThroughAliasPath_isNoOpAndKeepsOriginal() async throws {
        let real = try Fixture.makeDirectory(in: testRoot, name: "real")
        let file = try Fixture.makeFile(in: real, name: "note.txt")
        try "ORIGINAL".write(to: file, atomically: true, encoding: .utf8)
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: real)

        let mockResolver = resolver([.replace])
        let result = await FileOperations().move(items: [file], to: alias, resolver: mockResolver)

        XCTAssertTrue(result.failures.isEmpty, "별칭 경로로 같은 폴더에 이동이 실패함: \(result.failures)")
        XCTAssertEqual(result.skipped, [file], "같은 폴더로의 이동은 no-op이어야 함(Win10 동작 / M3 D&D 수용 기준)")
        let askedCount = await mockResolver.seenConflicts.count
        XCTAssertEqual(askedCount, 0, "같은 폴더 이동은 충돌 질의 자체가 없어야 함")
        XCTAssertTrue(exists(file), "원본이 사라졌다 — 데이터 손실")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ORIGINAL")
        XCTAssertFalse(exists(real.appendingPathComponent("note 2.txt")), "no-op이어야 하는데 사본이 생겼다")
    }

    /// 리뷰가 지목한 재현 시나리오: `/Users/admin/Desktop`로 이동 후 붙여넣기처럼
    /// **표기만 다른 같은 폴더**가 대상이 되는 경우.
    ///
    /// 대소문자를 정규화하면 "같은 폴더에 복사" 규칙(UI설계 §7.1)이 적용돼 충돌 질의 없이
    /// `note 2.txt`로 넘버링된다 — 원본은 그대로다.
    func testCopy_intoSameFolderSpelledWithDifferentCase_numbersCopyAndNeverAsksToReplace() async throws {
        try XCTSkipUnless(
            isCaseInsensitiveVolume(at: testRoot),
            "이 볼륨은 대소문자 구분이라 표기만 다른 같은 폴더를 만들 수 없음"
        )
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Desktop")
        let file = try Fixture.makeFile(in: folder, name: "note.txt")
        try "ORIGINAL".write(to: file, atomically: true, encoding: .utf8)
        // 같은 폴더를 소문자 표기로 가리킨다(대소문자 비구분 볼륨에서는 같은 폴더다).
        let sameFolderOtherSpelling = testRoot.appendingPathComponent("desktop", isDirectory: true)

        let mockResolver = resolver([.replace])
        let result = await FileOperations().copy(
            items: [file],
            to: sameFolderOtherSpelling,
            resolver: mockResolver
        )

        XCTAssertTrue(result.failures.isEmpty, "표기만 다른 같은 폴더 복사가 실패함: \(result.failures)")
        let askedCount = await mockResolver.seenConflicts.count
        XCTAssertEqual(askedCount, 0, "같은 폴더 복사는 충돌 질의 없이 넘버링되어야 함(UI설계 §7.1)")
        XCTAssertTrue(exists(file), "원본이 휴지통으로 사라졌다 — 데이터 손실(blocker 1)")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ORIGINAL")
        XCTAssertTrue(exists(folder.appendingPathComponent("note 2.txt")), "\"둘 다 유지\" 넘버링 사본이 없음")
    }

    func testMove_intoSameFolderSpelledWithDifferentCase_isNoOpAndKeepsOriginal() async throws {
        try XCTSkipUnless(
            isCaseInsensitiveVolume(at: testRoot),
            "이 볼륨은 대소문자 구분이라 표기만 다른 같은 폴더를 만들 수 없음"
        )
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Desktop")
        let file = try Fixture.makeFile(in: folder, name: "note.txt")
        try "ORIGINAL".write(to: file, atomically: true, encoding: .utf8)
        let sameFolderOtherSpelling = testRoot.appendingPathComponent("desktop", isDirectory: true)

        let mockResolver = resolver([.replace])
        let result = await FileOperations().move(
            items: [file],
            to: sameFolderOtherSpelling,
            resolver: mockResolver
        )

        XCTAssertTrue(result.failures.isEmpty, "표기만 다른 같은 폴더로의 이동이 실패함: \(result.failures)")
        XCTAssertEqual(result.skipped, [file], "잘라내기 후 같은 폴더 붙여넣기는 no-op이어야 함(Win10 동작)")
        let askedCount = await mockResolver.seenConflicts.count
        XCTAssertEqual(askedCount, 0, "같은 폴더 이동은 충돌 질의 자체가 없어야 함")
        XCTAssertTrue(exists(file), "원본이 사라졌다 — 데이터 손실(blocker 1)")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ORIGINAL")
    }

    // MARK: - Blocker 1-b: 덮어쓰기 대상이 원본의 *조상*

    /// 재현(M2 재리뷰 blocker 1): `Documents/Documents`를 `Documents`의 **상위 폴더**에 붙여넣고
    /// "덮어쓰기"를 고르면 대상(`Documents`)이 원본의 부모가 된다.
    /// - 대상 != 원본이라 `destinationIsSource` 가드에 안 걸리고
    /// - `destination(상위 폴더)`은 원본 안에 있지 않아 `destinationInsideSource` 가드에도 안 걸린다
    /// → 예전 코드는 `trashExisting(대상)`으로 **원본과 형제 파일까지 통째로** 휴지통에 보냈다.
    func testCopy_replaceOntoAncestorOfSource_isRejectedAndKeepsWholeSubtree() async throws {
        let outer = try Fixture.makeDirectory(in: testRoot, name: "Documents")
        let sibling = try Fixture.makeFile(in: outer, name: "sibling.txt")
        try "SIBLING".write(to: sibling, atomically: true, encoding: .utf8)
        let inner = try Fixture.makeDirectory(in: outer, name: "Documents")
        let innerFile = try Fixture.makeFile(in: inner, name: "inner.txt")

        // 붙여넣기 대상은 `outer`의 상위 폴더 → target == outer == 원본의 부모
        let result = await FileOperations().copy(items: [inner], to: testRoot, resolver: resolver([.replace]))

        XCTAssertEqual(result.failures.first?.error, .sourceInsideDestination, "대상이 원본의 조상인 덮어쓰기가 거부되지 않음")
        XCTAssertTrue(result.produced.isEmpty)
        XCTAssertTrue(exists(outer), "원본의 부모 폴더가 휴지통으로 갔다 — 데이터 손실(blocker 1)")
        XCTAssertTrue(exists(sibling), "형제 파일까지 함께 사라졌다 — 데이터 손실(blocker 1)")
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "SIBLING")
        XCTAssertTrue(exists(inner), "원본이 사라졌다 — 데이터 손실(blocker 1)")
        XCTAssertTrue(exists(innerFile))
    }

    func testMove_replaceOntoAncestorOfSource_isRejectedAndKeepsWholeSubtree() async throws {
        let outer = try Fixture.makeDirectory(in: testRoot, name: "Documents")
        let sibling = try Fixture.makeFile(in: outer, name: "sibling.txt")
        let inner = try Fixture.makeDirectory(in: outer, name: "Documents")
        let innerFile = try Fixture.makeFile(in: inner, name: "inner.txt")

        let result = await FileOperations().move(items: [inner], to: testRoot, resolver: resolver([.replace]))

        XCTAssertEqual(result.failures.first?.error, .sourceInsideDestination)
        XCTAssertTrue(exists(outer), "원본의 부모 폴더가 휴지통으로 갔다 — 데이터 손실(blocker 1)")
        XCTAssertTrue(exists(sibling))
        XCTAssertTrue(exists(inner))
        XCTAssertTrue(exists(innerFile))
    }

    /// 같은 포함 관계를 **심볼릭 링크 별칭 경로**로 만든 경우 — 경로 문자열 접두사가 전혀 겹치지 않아
    /// 문자열 비교만으로는 "대상이 원본의 조상"임을 알 수 없다(firmlink 별칭도 같은 형태다).
    func testCopy_replaceOntoAncestorReachedThroughAliasPath_isRejected() async throws {
        let real = try Fixture.makeDirectory(in: testRoot, name: "real")
        let outer = try Fixture.makeDirectory(in: real, name: "Documents")
        let sibling = try Fixture.makeFile(in: outer, name: "sibling.txt")
        let inner = try Fixture.makeDirectory(in: outer, name: "Documents")
        let innerFile = try Fixture.makeFile(in: inner, name: "inner.txt")
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: real)
        XCTAssertFalse(
            PathKey.isSameOrDescendant(inner, of: alias.appendingPathComponent("Documents", isDirectory: true)),
            "별칭 경로가 문자열로 포함 관계를 드러내면 이 테스트는 무의미하다"
        )

        let result = await FileOperations().copy(items: [inner], to: alias, resolver: resolver([.replace]))

        XCTAssertEqual(result.failures.first?.error, .sourceInsideDestination, "별칭 경로로 조상 덮어쓰기 가드가 뚫렸다(blocker 1)")
        XCTAssertTrue(exists(outer), "원본의 부모 폴더가 휴지통으로 갔다 — 데이터 손실(blocker 1)")
        XCTAssertTrue(exists(sibling))
        XCTAssertTrue(exists(inner))
        XCTAssertTrue(exists(innerFile))
    }

    /// 이름만 같고 포함 관계가 아닌 폴더 덮어쓰기는 계속 동작해야 한다(가드 과잉 확대 방지).
    func testCopy_replaceOntoSameNamedFolderThatIsNotAnAncestor_stillReplaces() async throws {
        let existing = try Fixture.makeDirectory(in: testRoot, name: "Documents")
        try "OLD".write(to: existing.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        let elsewhere = try Fixture.makeDirectory(in: testRoot, name: "elsewhere")
        let source = try Fixture.makeDirectory(in: elsewhere, name: "Documents")
        try "NEW".write(to: source.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let result = await FileOperations().copy(items: [source], to: testRoot, resolver: resolver([.replace]))

        XCTAssertTrue(result.failures.isEmpty, "정상적인 동명 폴더 덮어쓰기까지 막으면 안 됨: \(result.failures)")
        XCTAssertTrue(exists(existing.appendingPathComponent("new.txt")), "대체가 일어나지 않음")
        XCTAssertFalse(exists(existing.appendingPathComponent("old.txt")), "폴더 덮어쓰기는 병합이 아니라 대체여야 함")
    }

    // MARK: - Blocker 2: transfer 경로의 보호 대상 가드

    /// 홈 루트를 **잘라내기 → 다른 폴더에 붙여넣기** 하는 경로.
    /// `trash(items:)`/`rename`과 같은 판정(`isProtected`)이 `move`에도 적용되어야 한다.
    func testMove_protectedSource_isRejectedAndLeavesItInPlace() async throws {
        let fakeHome = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        let keep = try Fixture.makeFile(in: fakeHome, name: "keep.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let operations = FileOperations(homeDirectory: fakeHome)

        let result = await operations.move(items: [fakeHome], to: destination, resolver: resolver())

        XCTAssertEqual(result.failures.first?.error, .protectedTarget, "보호 대상 이동이 막히지 않음(blocker 2)")
        XCTAssertTrue(result.produced.isEmpty)
        XCTAssertTrue(exists(keep), "홈 루트가 통째로 이동됐다 — 데이터 손실(blocker 2)")
        XCTAssertFalse(exists(destination.appendingPathComponent("fake-home")), "대상에 이동 결과가 만들어지면 안 됨")
    }

    /// 같은 대상을 `copy`로 요청하는 것은 파괴적이지 않으므로 계속 허용되어야 한다
    /// (가드를 과하게 넓혀 정상 동작을 막지 않았는지 확인).
    func testCopy_protectedSource_isStillAllowed() async throws {
        let fakeHome = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        _ = try Fixture.makeFile(in: fakeHome, name: "keep.txt")
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let operations = FileOperations(homeDirectory: fakeHome)

        let result = await operations.copy(items: [fakeHome], to: destination, resolver: resolver())

        XCTAssertTrue(result.failures.isEmpty, "보호 대상 복사(비파괴)까지 막으면 안 됨: \(result.failures)")
        XCTAssertTrue(exists(destination.appendingPathComponent("fake-home/keep.txt")))
        XCTAssertTrue(exists(fakeHome.appendingPathComponent("keep.txt")))
    }

    /// 덮어쓰기 대상이 홈 루트인 경우 — `.replace`는 대상을 휴지통으로 보내므로 삭제와 같다.
    /// (실제 재현: `/Users`에 사용자 이름과 같은 이름의 폴더를 붙여넣고 "덮어쓰기" 선택)
    func testCopy_replaceOntoProtectedTarget_isRejectedAndKeepsTarget() async throws {
        let usersFolder = try Fixture.makeDirectory(in: testRoot, name: "Users")
        let fakeHome = try Fixture.makeDirectory(in: usersFolder, name: "admin")
        let keep = try Fixture.makeFile(in: fakeHome, name: "keep.txt")

        let elsewhere = try Fixture.makeDirectory(in: testRoot, name: "elsewhere")
        let impostor = try Fixture.makeDirectory(in: elsewhere, name: "admin")
        _ = try Fixture.makeFile(in: impostor, name: "new.txt")

        let operations = FileOperations(homeDirectory: fakeHome)
        let result = await operations.copy(items: [impostor], to: usersFolder, resolver: resolver([.replace]))

        XCTAssertEqual(result.failures.first?.error, .protectedTarget, "보호 대상 덮어쓰기가 막히지 않음(blocker 2)")
        XCTAssertTrue(exists(keep), "홈 루트가 덮어쓰기로 휴지통에 갔다 — 데이터 손실(blocker 2)")
        XCTAssertFalse(exists(fakeHome.appendingPathComponent("new.txt")), "보호 대상이 교체되면 안 됨")
    }

    func testMove_replaceOntoProtectedTarget_isRejectedAndKeepsBothSides() async throws {
        let usersFolder = try Fixture.makeDirectory(in: testRoot, name: "Users")
        let fakeHome = try Fixture.makeDirectory(in: usersFolder, name: "admin")
        let keep = try Fixture.makeFile(in: fakeHome, name: "keep.txt")

        let elsewhere = try Fixture.makeDirectory(in: testRoot, name: "elsewhere")
        let impostor = try Fixture.makeDirectory(in: elsewhere, name: "admin")

        let operations = FileOperations(homeDirectory: fakeHome)
        let result = await operations.move(items: [impostor], to: usersFolder, resolver: resolver([.replace]))

        XCTAssertEqual(result.failures.first?.error, .protectedTarget)
        XCTAssertTrue(exists(keep), "보호 대상이 이동 덮어쓰기로 사라졌다 — 데이터 손실(blocker 2)")
        XCTAssertTrue(exists(impostor), "거부된 이동은 원본도 그대로여야 함")
    }

    /// 일반 항목의 덮어쓰기는 그대로 동작해야 한다(가드가 정상 경로를 막지 않는지).
    func testCopy_replaceOntoOrdinaryTarget_stillReplaces() async throws {
        let source = try Fixture.makeFile(in: testRoot, name: "note.txt")
        try "NEW".write(to: source, atomically: true, encoding: .utf8)
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let existing = destination.appendingPathComponent("note.txt")
        try "OLD".write(to: existing, atomically: true, encoding: .utf8)

        let result = await FileOperations().copy(items: [source], to: destination, resolver: resolver([.replace]))

        XCTAssertTrue(result.failures.isEmpty, "일반 덮어쓰기까지 막으면 안 됨: \(result.failures)")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "NEW")
    }

    // MARK: - 근본 원인 회귀: 대소문자만 바꾸는 rename은 계속 동작해야 한다

    /// `PathKey.key`가 소문자 정규화로 바뀌었으므로, "이름이 그대로인가" 판정에 그 키를 쓰면
    /// `readme.txt` → `README.txt`가 조용히 무동작이 된다. 표기 비교로 분리했는지 고정한다.
    func testRename_caseOnlyChange_isNotTreatedAsNoOp() async throws {
        let file = try Fixture.makeFile(in: testRoot, name: "readme.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let result = await FileOperations().rename(item: file, to: "README.txt")

        XCTAssertTrue(result.failures.isEmpty, "대소문자만 다른 이름 변경이 실패함: \(result.failures)")
        XCTAssertEqual(result.produced.first?.lastPathComponent, "README.txt", "대소문자 변경이 무동작으로 흡수되면 안 됨")
        let entries = try FileManager.default.contentsOfDirectory(atPath: testRoot.path)
        XCTAssertEqual(entries, ["README.txt"], "디스크상의 실제 이름이 바뀌어야 함")
        XCTAssertEqual(try String(contentsOf: result.produced[0], encoding: .utf8), "hello")
    }

    func testRename_identicalName_isStillNoOp() async throws {
        let file = try Fixture.makeFile(in: testRoot, name: "same.txt")

        let result = await FileOperations().rename(item: file, to: "same.txt")

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.produced, [file])
        XCTAssertTrue(exists(file))
    }
}
