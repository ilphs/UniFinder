import XCTest
@testable import UniFinder

/// `DirectoryLoader` (actor, `DirectoryListing` 준수) 단위 테스트.
/// 대상(T1 수용 기준): 숨김 필터, 심볼릭 링크 플래그, 권한 에러, 빈 폴더,
/// 한글/이모지/255자 이름, 취소 시 결과 미방출.
/// 정렬 자체는 `FileItemSortTests`에서 순수 함수로 별도 검증한다(로더는 정렬을 하지 않고
/// 원본 목록만 반환한다고 가정 — DirectoryModel이 정렬을 적용한다, 설계서 §3.3).
final class DirectoryLoaderTests: TempDirectoryTestCase {

    // MARK: - 빈 폴더

    func testList_emptyDirectory_returnsEmptyArray() async throws {
        let loader = DirectoryLoader()
        let items = try await loader.list(at: testRoot, showHidden: false)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - 숨김 필터

    func testList_showHiddenFalse_excludesHiddenItems() async throws {
        try Fixture.makeFile(in: testRoot, name: "visible.txt")
        try Fixture.makeFile(in: testRoot, name: ".hidden.txt")

        let loader = DirectoryLoader()
        let items = try await loader.list(at: testRoot, showHidden: false)

        XCTAssertEqual(items.map(\.name).sorted(), ["visible.txt"])
    }

    func testList_showHiddenTrue_includesHiddenItemsWithFlagSet() async throws {
        try Fixture.makeFile(in: testRoot, name: "visible.txt")
        try Fixture.makeFile(in: testRoot, name: ".hidden.txt")

        let loader = DirectoryLoader()
        let items = try await loader.list(at: testRoot, showHidden: true)

        XCTAssertEqual(items.count, 2)
        guard let hidden = items.first(where: { $0.name == ".hidden.txt" }) else {
            return XCTFail("숨김 파일이 목록에 없음")
        }
        XCTAssertTrue(hidden.isHidden)

        guard let visible = items.first(where: { $0.name == "visible.txt" }) else {
            return XCTFail("일반 파일이 목록에 없음")
        }
        XCTAssertFalse(visible.isHidden)
    }

    // MARK: - 심볼릭 링크

    func testList_symlinkToDirectory_flagsIsSymlinkAndReflectsTargetType() async throws {
        let targetDir = try Fixture.makeDirectory(in: testRoot, name: "target")
        try Fixture.makeSymlink(in: testRoot, name: "link", destination: targetDir)

        let loader = DirectoryLoader()
        let items = try await loader.list(at: testRoot, showHidden: false)

        guard let link = items.first(where: { $0.name == "link" }) else {
            return XCTFail("심볼릭 링크가 목록에 없음")
        }
        XCTAssertTrue(link.isSymlink)
        XCTAssertTrue(link.isDirectory, "심볼릭 링크는 타겟(폴더)의 종류를 반영해야 함")
    }

    func testList_symlinkToFile_flagsIsSymlink() async throws {
        let targetFile = try Fixture.makeFile(in: testRoot, name: "target.txt")
        try Fixture.makeSymlink(in: testRoot, name: "link.txt", destination: targetFile)

        let loader = DirectoryLoader()
        let items = try await loader.list(at: testRoot, showHidden: false)

        guard let link = items.first(where: { $0.name == "link.txt" }) else {
            return XCTFail("심볼릭 링크가 목록에 없음")
        }
        XCTAssertTrue(link.isSymlink)
        XCTAssertFalse(link.isDirectory)
    }

    // MARK: - 권한 에러

    func testList_permissionDenied_throwsAccessDenied() async throws {
        let (deniedURL, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "locked")
        defer { restore() }

        let loader = DirectoryLoader()
        do {
            _ = try await loader.list(at: deniedURL, showHidden: false)
            XCTFail("권한 없는 폴더 열거가 실패하지 않음")
        } catch let error as DirectoryError {
            XCTAssertEqual(error, .accessDenied)
        }
    }

    // MARK: - 한글/이모지/255자 이름

    func testList_koreanFileName_isPreservedExactly() async throws {
        try Fixture.makeFile(in: testRoot, name: "한글_파일이름.txt")

        let loader = DirectoryLoader()
        let items = try await loader.list(at: testRoot, showHidden: false)

        XCTAssertEqual(items.map(\.name), ["한글_파일이름.txt"])
    }

    func testList_emojiFileName_isPreservedExactly() async throws {
        try Fixture.makeFile(in: testRoot, name: "여행📸사진🌊.txt")

        let loader = DirectoryLoader()
        let items = try await loader.list(at: testRoot, showHidden: false)

        XCTAssertEqual(items.map(\.name), ["여행📸사진🌊.txt"])
    }

    func testList_maxLengthFileName_255chars_isHandled() async throws {
        let longName = Fixture.maxLengthName()
        XCTAssertEqual(longName.count, 255)
        try Fixture.makeFile(in: testRoot, name: longName)

        let loader = DirectoryLoader()
        let items = try await loader.list(at: testRoot, showHidden: false)

        XCTAssertEqual(items.map(\.name), [longName])
    }

    // MARK: - 취소

    func testList_cancelledTask_throwsCancellationAndYieldsNoResults() async throws {
        // 열거 루프 중 checkCancellation 지점이 존재하도록 항목 다수 생성.
        for i in 0..<300 {
            try Fixture.makeFile(in: testRoot, name: "file_\(i).txt")
        }

        let loader = DirectoryLoader()
        let task = Task {
            try await loader.list(at: self.testRoot, showHidden: false)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("취소된 요청이 결과를 반환함")
        } catch is CancellationError {
            // 기대한 경로
        } catch {
            XCTFail("CancellationError가 아닌 다른 에러: \(error)")
        }
    }

    // MARK: - 존재하지 않는 경로

    func testList_nonexistentPath_throwsError() async throws {
        let missing = testRoot.appendingPathComponent("does-not-exist")
        let loader = DirectoryLoader()
        do {
            _ = try await loader.list(at: missing, showHidden: false)
            XCTFail("존재하지 않는 경로 열거가 실패하지 않음")
        } catch {
            // 구체 타입은 구현에 위임 — 에러가 던져지는 것만 검증
        }
    }
}
