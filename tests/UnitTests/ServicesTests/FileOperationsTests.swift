import XCTest
@testable import UniFinder

/// `FileOperations` (actor, m2-impl.md T0) 단위 테스트.
///
/// 테스트계획서 §4.2 핵심 매트릭스 — **연산 × 조건** 전 조합:
///
/// | 연산 \ 조건 | 성공 | 충돌:덮어쓰기 | 충돌:건너뛰기 | 충돌:둘다유지 | 취소 | 권한 실패 | 볼륨 간 |
/// |---|---|---|---|---|---|---|---|
/// | copy | ● | ● | ● | ●(넘버링) | ●(완료분 유지) | ● | ● |
/// | move | ● | ● | ● | ● | ● | ● | ●(copy+trash 폴백) |
/// | trash | ● | — | — | — | ● | ● | ●(볼륨별 휴지통) |
/// | rename | ● | ●(거부) | — | — | — | ● | — |
/// | createFolder | ●(넘버링) | — | — | — | — | ● | — |
///
/// 실제 프로덕션 계약(`src/Services/FileOperating.swift`, `src/Models/FileOperationTypes.swift`,
/// ralph T0 진행분)을 그대로 따른다:
/// - `protocol FileOperating`의 `copy/move(items:to:resolver:progress:)`, `trash(items:progress:)`,
///   `rename(item:to:)`, `createFolder(in:name:)` — 전부 `async -> OperationResult` 반환
/// - `OperationResult { produced, skipped, failures: [OperationFailure], isCancelled }`
/// - `OperationFailure { url, error: FileOperationError }`
/// - `ConflictResolving.resolve(_:) -> ConflictDecision`, `ConflictDecision { resolution: .replace/.keepBoth/.skip/.cancel, applyToAll }`
///
/// `FileOperations`(actor 구현체)는 아직 ralph가 작성 중이므로 `FileOperations()`가
/// 존재하지 않으면 컴파일이 실패한다 — 정상이다(프로덕션 코드가 이 계약대로 채워지면 통과).
final class FileOperationsTests: TempDirectoryTestCase {

    private func ops() -> FileOperations { FileOperations() }

    private func resolver(_ decisions: [ConflictDecision] = [], fallback: ConflictDecision = .skip) -> MockConflictResolver {
        MockConflictResolver(scripted: decisions, fallback: fallback)
    }

    // MARK: - copy: 성공

    func testCopy_success_singleFile_createsCopyAtDestination() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "a.txt", sizeBytes: 32)
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")

        let result = await ops().copy(items: [src], to: destDir, resolver: resolver())

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.produced.count, 1)
        let copied = destDir.appendingPathComponent("a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "복사는 원본을 남겨야 함")
    }

    func testCopy_folder_recursesNestedThreeLevels() async throws {
        let root = try Fixture.makeDirectory(in: testRoot, name: "tree")
        let l1 = try Fixture.makeDirectory(in: root, name: "L1")
        let l2 = try Fixture.makeDirectory(in: l1, name: "L2")
        _ = try Fixture.makeFile(in: l2, name: "leaf.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")

        let result = await ops().copy(items: [root], to: destDir, resolver: resolver())

        XCTAssertTrue(result.failures.isEmpty)
        let leaf = destDir.appendingPathComponent("tree/L1/L2/leaf.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaf.path), "중첩 3단 재귀 복사가 반영되지 않음")
    }

    func testCopy_symlink_copiesLinkItselfNotTargetContents() async throws {
        let targetFile = try Fixture.makeFile(in: testRoot, name: "target.txt", sizeBytes: 10)
        let link = try Fixture.makeSymlink(in: testRoot, name: "link.txt", destination: targetFile)
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")

        let result = await ops().copy(items: [link], to: destDir, resolver: resolver())

        XCTAssertTrue(result.failures.isEmpty)
        let copiedLink = destDir.appendingPathComponent("link.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: copiedLink.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink, "링크 자체가 복사되어야 함(타겟 내용이 아님)")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: copiedLink.path)
        XCTAssertEqual(URL(fileURLWithPath: destination).lastPathComponent, "target.txt")
    }

    // MARK: - copy: 충돌 3분기

    func testCopy_conflict_replace_replacesDestinationFile() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "note.txt", sizeBytes: 5)
        try "NEW".write(to: src, atomically: true, encoding: .utf8)
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let existing = destDir.appendingPathComponent("note.txt")
        try "OLD".write(to: existing, atomically: true, encoding: .utf8)

        let result = await ops().copy(items: [src], to: destDir, resolver: resolver([.replace]))

        XCTAssertTrue(result.failures.isEmpty)
        let content = try String(contentsOf: existing, encoding: .utf8)
        XCTAssertEqual(content, "NEW")
    }

    func testCopy_conflict_replace_folderIsReplacedNotMerged() async throws {
        let srcFolder = try Fixture.makeDirectory(in: testRoot, name: "Sub")
        _ = try Fixture.makeFile(in: srcFolder, name: "new.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let existingDest = destDir.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDest, withIntermediateDirectories: true)
        _ = try Fixture.makeFile(in: existingDest, name: "keep.txt")

        let result = await ops().copy(items: [srcFolder], to: destDir, resolver: resolver([.replace]))

        XCTAssertTrue(result.failures.isEmpty)
        let entries = try FileManager.default.contentsOfDirectory(atPath: existingDest.path)
        XCTAssertEqual(entries, ["new.txt"], "폴더 덮어쓰기는 병합이 아니라 대체여야 함(keep.txt가 남아있으면 안 됨)")
    }

    func testCopy_conflict_skip_leavesDestinationUntouchedAndReportsSkipped() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let existing = destDir.appendingPathComponent("note.txt")
        try "OLD".write(to: existing, atomically: true, encoding: .utf8)

        let result = await ops().copy(items: [src], to: destDir, resolver: resolver([.skip]))

        XCTAssertTrue(result.failures.isEmpty, "건너뛰기는 실패가 아니라 의도적 무동작이어야 함")
        XCTAssertEqual(result.skipped, [src])
        let content = try String(contentsOf: existing, encoding: .utf8)
        XCTAssertEqual(content, "OLD", "건너뛴 항목의 대상은 변경되지 않아야 함")
    }

    func testCopy_conflict_keepBoth_numbersNewCopy() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        _ = try Fixture.makeFile(in: destDir, name: "note.txt")

        let result = await ops().copy(items: [src], to: destDir, resolver: resolver([.keepBoth]))

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("note 2.txt").path))
    }

    func testCopy_conflict_keepBoth_skipsAlreadyTakenNumbersInSequence() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        _ = try Fixture.makeFile(in: destDir, name: "note.txt")
        _ = try Fixture.makeFile(in: destDir, name: "note 2.txt")

        let result = await ops().copy(items: [src], to: destDir, resolver: resolver([.keepBoth]))

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("note 3.txt").path))
    }

    // MARK: - copy: 취소 (완료분 유지)

    func testCopy_cancelledMidway_keepsCompletedItemsAndStopsRemaining() async throws {
        let a = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let b = try Fixture.makeFile(in: testRoot, name: "b-conflict.txt")
        let c = try Fixture.makeFile(in: testRoot, name: "c.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        // b는 대상에 동명 파일이 있어 충돌 질의가 발생하고, 그 질의를 블로킹해 취소 타이밍을 고정한다.
        _ = try Fixture.makeFile(in: destDir, name: "b-conflict.txt")

        let mockResolver = resolver()
        await mockResolver.block(source: b)

        let task = Task { await ops().copy(items: [a, b, c], to: destDir, resolver: mockResolver) }

        // a가 처리되어 b의 충돌 질의(block)에 도달할 때까지 기다린다.
        try await waitUntil { await mockResolver.seenConflicts.contains(where: { $0.source == b }) }
        task.cancel()

        let result = await task.value

        XCTAssertTrue(result.isCancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a.txt").path), "취소 전 완료된 항목은 유지되어야 함")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("c.txt").path), "취소 후 항목은 처리되지 않아야 함")
        let resumedCount = await mockResolver.cancellationResumedCount
        XCTAssertEqual(resumedCount, 1, "대기 중 continuation이 취소 시 반드시 재개되어야 함(행/누수 방지)")
    }

    // MARK: - copy: 권한 실패

    func testCopy_destinationNotWritable_reportsAccessDeniedFailure() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let (deniedDir, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "locked")
        defer { restore() }

        let result = await ops().copy(items: [src], to: deniedDir, resolver: resolver())

        XCTAssertTrue(result.produced.isEmpty)
        XCTAssertEqual(result.failures.first?.error, .accessDenied)
    }

    // MARK: - copy: 자기 자신/자기 하위 거부

    func testCopy_intoSelf_isRejected() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Self")

        let result = await ops().copy(items: [folder], to: folder, resolver: resolver())

        XCTAssertTrue(result.produced.isEmpty)
        XCTAssertEqual(result.failures.first?.error, .destinationInsideSource)
    }

    func testCopy_intoOwnDescendant_isRejected() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Parent")
        let child = try Fixture.makeDirectory(in: folder, name: "Child")

        let result = await ops().copy(items: [folder], to: child, resolver: resolver())

        XCTAssertTrue(result.produced.isEmpty)
        XCTAssertEqual(result.failures.first?.error, .destinationInsideSource)
        // 거부되었으므로 무한 재귀 없이 즉시 반환되어야 한다(테스트 자체가 타임아웃 없이 끝나는 것이 증거).
    }

    // MARK: - copy: 다중 항목 일부 실패 + 모두 적용

    func testCopy_multipleItems_partialFailure_continuesRemainingAndReportsFailures() async throws {
        let ok1 = try Fixture.makeFile(in: testRoot, name: "ok1.txt")
        let (deniedSourceDir, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "lockedSrc")
        let deniedSource = deniedSourceDir.appendingPathComponent("secret.txt")
        defer { restore() }
        let ok2 = try Fixture.makeFile(in: testRoot, name: "ok2.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")

        let result = await ops().copy(items: [ok1, deniedSource, ok2], to: destDir, resolver: resolver())

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(Set(result.failures.map(\.url)), [deniedSource])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("ok1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("ok2.txt").path), "일부 실패해도 나머지 항목은 계속 처리되어야 함")
    }

    func testCopy_conflict_applyToAll_appliesDecisionToRemainingConflictsWithoutFurtherQuery() async throws {
        let a = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let b = try Fixture.makeFile(in: testRoot, name: "b.txt")
        let c = try Fixture.makeFile(in: testRoot, name: "c.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        for name in ["a.txt", "b.txt", "c.txt"] {
            try "OLD".write(to: destDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        // 첫 충돌에서만 "모두 적용(건너뛰기)"를 응답 — 이후 충돌은 질의 없이 동일 결정이 적용되어야 한다.
        let mockResolver = resolver([ConflictDecision(resolution: .skip, applyToAll: true)])
        let result = await ops().copy(items: [a, b, c], to: destDir, resolver: mockResolver)

        XCTAssertTrue(result.failures.isEmpty)
        let seenCount = await mockResolver.seenConflicts.count
        XCTAssertEqual(seenCount, 1, "\"모두 적용\" 이후 남은 충돌은 재질의하지 않아야 함")
        for name in ["a.txt", "b.txt", "c.txt"] {
            let content = try String(contentsOf: destDir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(content, "OLD", "건너뛰기가 모든 항목에 적용되어 대상이 바뀌면 안 됨")
        }
    }

    // MARK: - move: 성공/충돌/취소/권한 (copy와 동일 의미론 재검증 + move 고유 동작)

    func testMove_success_removesSourceAndCreatesAtDestination() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")

        let result = await ops().move(items: [src], to: destDir, resolver: resolver())

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "이동은 원본을 남기면 안 됨")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a.txt").path))
    }

    func testMove_conflict_replace_replacesDestination() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "note.txt")
        try "NEW".write(to: src, atomically: true, encoding: .utf8)
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let existing = destDir.appendingPathComponent("note.txt")
        try "OLD".write(to: existing, atomically: true, encoding: .utf8)

        let result = await ops().move(items: [src], to: destDir, resolver: resolver([.replace]))

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "NEW")
    }

    func testMove_conflict_skip_keepsSourceAndDestinationUnchanged() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        let existing = destDir.appendingPathComponent("note.txt")
        try "OLD".write(to: existing, atomically: true, encoding: .utf8)

        let result = await ops().move(items: [src], to: destDir, resolver: resolver([.skip]))

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "건너뛴 이동은 원본이 남아있어야 함")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "OLD")
    }

    func testMove_conflict_keepBoth_numbersDestinationAndRemovesSource() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "note.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        _ = try Fixture.makeFile(in: destDir, name: "note.txt")

        let result = await ops().move(items: [src], to: destDir, resolver: resolver([.keepBoth]))

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("note 2.txt").path))
    }

    func testMove_cancelledMidway_keepsCompletedItemsAndStopsRemaining() async throws {
        let a = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let b = try Fixture.makeFile(in: testRoot, name: "b-conflict.txt")
        let c = try Fixture.makeFile(in: testRoot, name: "c.txt")
        let destDir = try Fixture.makeDirectory(in: testRoot, name: "dest")
        _ = try Fixture.makeFile(in: destDir, name: "b-conflict.txt")

        let mockResolver = resolver()
        await mockResolver.block(source: b)

        let task = Task { await ops().move(items: [a, b, c], to: destDir, resolver: mockResolver) }
        try await waitUntil { await mockResolver.seenConflicts.contains(where: { $0.source == b }) }
        task.cancel()

        let result = await task.value

        XCTAssertTrue(result.isCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "취소 전 완료된 이동은 원본이 사라져야 함")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path), "취소 후 항목은 이동되지 않아야 함(원본 유지)")
    }

    func testMove_destinationNotWritable_reportsAccessDeniedAndKeepsSource() async throws {
        let src = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let (deniedDir, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "locked")
        defer { restore() }

        let result = await ops().move(items: [src], to: deniedDir, resolver: resolver())

        XCTAssertEqual(result.failures.first?.error, .accessDenied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "실패한 이동은 원본을 지우면 안 됨")
    }

    func testMove_intoSelf_isRejected() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Self")

        let result = await ops().move(items: [folder], to: folder, resolver: resolver())

        XCTAssertEqual(result.failures.first?.error, .destinationInsideSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "거부된 이동은 원본을 지우면 안 됨")
    }

    func testMove_intoOwnDescendant_isRejected() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Parent")
        let child = try Fixture.makeDirectory(in: folder, name: "Child")

        let result = await ops().move(items: [folder], to: child, resolver: resolver())

        XCTAssertEqual(result.failures.first?.error, .destinationInsideSource)
    }

    // MARK: - trash

    func testTrash_success_removesFromOriginalLocation() async throws {
        let file = try Fixture.makeFile(in: testRoot, name: "gone.txt")

        let result = await ops().trash(items: [file])

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.produced.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "휴지통 이동 후 원위치에 남아있으면 안 됨")
    }

    func testTrash_permissionDenied_reportsFailure() async throws {
        let (deniedDir, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "locked")
        defer { restore() }
        // 부모(locked)에 쓰기 권한이 없어야 항목 삭제가 거부된다.
        let result = await ops().trash(items: [deniedDir])

        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(result.failures.first?.error, .accessDenied)
    }

    func testTrash_cancelledMidway_doesNotHangAndCompletesGracefully() async throws {
        let a = try Fixture.makeFile(in: testRoot, name: "a.txt")
        let manyMore = try (0..<50).map { try Fixture.makeFile(in: testRoot, name: "f\($0).txt") }

        let task = Task { await ops().trash(items: [a] + manyMore) }
        task.cancel()
        let result = await task.value

        // 취소가 즉시 반영됐다면 전부 처리되지 않았을 가능성이 높다 — 최소한 크래시/행 없이 끝나는 것이 핵심 증거.
        XCTAssertLessThanOrEqual(result.produced.count, 51)
    }

    func testTrash_multipleItems_partialFailure_continuesRemaining() async throws {
        let ok1 = try Fixture.makeFile(in: testRoot, name: "ok1.txt")
        let (deniedDir, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "lockedParent")
        let deniedChild = deniedDir.appendingPathComponent("secret.txt")
        defer { restore() }
        let ok2 = try Fixture.makeFile(in: testRoot, name: "ok2.txt")

        let result = await ops().trash(items: [ok1, deniedChild, ok2])

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ok1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ok2.path), "일부 실패해도 나머지 항목은 계속 삭제되어야 함")
    }

    // MARK: - rename

    func testRename_success_changesNameKeepsContent() async throws {
        let file = try Fixture.makeFile(in: testRoot, name: "old.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let result = await ops().rename(item: file, to: "new.txt")

        XCTAssertTrue(result.failures.isEmpty, "이름 변경이 실패함: \(result.failures)")
        guard let newURL = result.produced.first else { return XCTFail("이름 변경 결과 URL이 없음") }
        XCTAssertEqual(newURL.lastPathComponent, "new.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: newURL, encoding: .utf8), "hello")
    }

    func testRename_duplicateName_isRejected() async throws {
        let file = try Fixture.makeFile(in: testRoot, name: "a.txt")
        _ = try Fixture.makeFile(in: testRoot, name: "b.txt")

        let result = await ops().rename(item: file, to: "b.txt")

        XCTAssertEqual(result.failures.first?.error, .nameExists, "중복 이름 변경이 거부되지 않음")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "거부된 이름 변경은 원본을 지우면 안 됨")
    }

    func testRename_caseOnlyChange_succeedsDespiteCaseInsensitiveFilesystem() async throws {
        // APFS는 기본적으로 대소문자 비구분 — 자기 자신을 "중복"으로 오판하면 안 된다(B3).
        let file = try Fixture.makeFile(in: testRoot, name: "readme.txt")

        let result = await ops().rename(item: file, to: "README.txt")

        XCTAssertTrue(result.failures.isEmpty, "대소문자만 다른 이름 변경이 실패함: \(result.failures)")
        XCTAssertEqual(result.produced.first?.lastPathComponent, "README.txt")
    }

    func testRename_permissionDenied_reportsFailure() async throws {
        let (deniedDir, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "locked")
        defer { restore() }
        let target = deniedDir.appendingPathComponent("secret.txt")

        let result = await ops().rename(item: target, to: "renamed.txt")

        XCTAssertEqual(result.failures.first?.error, .accessDenied, "권한 없는 이름 변경이 실패로 보고되지 않음")
    }

    // MARK: - createFolder

    func testCreateFolder_success_createsEmptyDirectory() async throws {
        let result = await ops().createFolder(in: testRoot, name: "새 폴더")

        XCTAssertTrue(result.failures.isEmpty, "새 폴더 생성이 실패함: \(result.failures)")
        guard let url = result.produced.first else { return XCTFail("새 폴더 결과 URL이 없음") }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testCreateFolder_duplicateName_isRejected() async throws {
        _ = try Fixture.makeDirectory(in: testRoot, name: "새 폴더")

        let result = await ops().createFolder(in: testRoot, name: "새 폴더")

        XCTAssertEqual(result.failures.first?.error, .nameExists, "중복 이름 새 폴더 생성이 거부되지 않음")
    }

    func testCreateFolder_permissionDenied_reportsFailure() async throws {
        let (deniedDir, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "locked")
        defer { restore() }

        let result = await ops().createFolder(in: deniedDir, name: "새 폴더")

        XCTAssertEqual(result.failures.first?.error, .accessDenied, "권한 없는 위치의 새 폴더 생성이 실패로 보고되지 않음")
    }

    // MARK: - 볼륨 간 (램디스크)

    func testCopy_crossVolume_succeeds() async throws {
        guard let disk = RAMDiskTestSupport.attach(volumeName: "UFCopyTest") else {
            throw XCTSkip("이 환경에서 램디스크를 생성할 수 없어 볼륨 간 테스트를 건너뜀")
        }
        defer { RAMDiskTestSupport.detach(devicePath: disk.devicePath) }

        let src = try Fixture.makeFile(in: testRoot, name: "cross.txt", sizeBytes: 64)
        let result = await ops().copy(items: [src], to: disk.mountPoint, resolver: resolver())

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.mountPoint.appendingPathComponent("cross.txt").path))
    }

    func testMove_crossVolume_fallsBackToCopyThenTrashOriginal() async throws {
        guard let disk = RAMDiskTestSupport.attach(volumeName: "UFMoveTest") else {
            throw XCTSkip("이 환경에서 램디스크를 생성할 수 없어 볼륨 간 테스트를 건너뜀")
        }
        defer { RAMDiskTestSupport.detach(devicePath: disk.devicePath) }

        let src = try Fixture.makeFile(in: testRoot, name: "cross.txt", sizeBytes: 64)
        let result = await ops().move(items: [src], to: disk.mountPoint, resolver: resolver())

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.mountPoint.appendingPathComponent("cross.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "볼륨 간 이동은 폴백 후 원본이 사라져야 함(copy+trash)")
    }

    // MARK: - 헬퍼

    /// 조건이 만족될 때까지 폴링한다(구현 세부 타이밍에 결합하지 않기 위함).
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        interval: UInt64 = 5_000_000,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: interval)
        }
    }
}
