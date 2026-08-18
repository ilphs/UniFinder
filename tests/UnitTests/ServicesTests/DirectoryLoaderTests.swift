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

    // MARK: - 심볼릭 링크 폴더를 열거 대상으로 직접 넘기는 경로 (2026-08-18 회귀)

    /// **재현 시나리오**: 좌측 트리에서 `~/Dropbox`(FileProvider 도메인 마운트를 가리키는 심볼릭
    /// 링크) 노드를 선택하면 우측 pane이 "Not a Folder"로 떨어졌다. 우측 목록에서 같은 폴더를
    /// 더블클릭하면 정상이었다 — `AppModel.resolveTarget(of:)`가 링크를 먼저 해석하기 때문.
    ///
    /// 원인은 `list(at:)` 한 함수 안에서 두 개의 심볼릭 링크 의미론이 충돌한 것:
    /// 가드의 `fileExists(atPath:isDirectory:)`는 `stat(2)`라 링크를 **따라가** 통과시키는데,
    /// 바로 다음 줄의 `contentsOfDirectory(at:)`는 링크를 따라가지 않아 `ENOTDIR`로 실패했다.
    ///
    /// 기존 심볼릭 링크 테스트는 링크를 **포함한** 폴더를 열거하는 케이스뿐이라(위 두 테스트)
    /// 이 버그를 잡지 못했다. 여기서는 링크 URL 자체를 `list(at:)`의 인자로 넘긴다.
    func testList_symlinkDirectoryURLItself_enumeratesTargetContents() async throws {
        let targetDir = try Fixture.makeDirectory(in: testRoot, name: "target")
        try Fixture.makeFile(in: targetDir, name: "inside.txt")
        try Fixture.makeDirectory(in: targetDir, name: "nested")
        let link = try Fixture.makeSymlink(in: testRoot, name: "link", destination: targetDir)

        let loader = DirectoryLoader()
        do {
            let items = try await loader.list(at: link, showHidden: false)
            XCTAssertEqual(items.map(\.name).sorted(), ["inside.txt", "nested"])
        } catch let error as DirectoryError {
            XCTFail("심볼릭 링크 폴더 열거가 \(error)로 실패함(트리 선택 시 'Not a Folder'의 원인)")
        }
    }

    /// **불변식 회귀 방지 — 이 테스트가 핵심이다.**
    /// 열거 대상만 링크를 해석하고, 자식 URL의 부모 표기는 호출자가 넘긴 링크 경로를 유지해야 한다.
    /// (`makeItem(parent:)` 주석의 계약 — 트리 `nodeIndex` 키 / `navigation.currentURL` /
    ///  주소창 표기가 사용자가 고른 경로 하나로 일관되게 남아야 한다)
    func testList_symlinkDirectoryURLItself_keepsLinkPathInChildURLs() async throws {
        let targetDir = try Fixture.makeDirectory(in: testRoot, name: "target")
        try Fixture.makeFile(in: targetDir, name: "inside.txt")
        try Fixture.makeDirectory(in: targetDir, name: "nested")
        let link = try Fixture.makeSymlink(in: testRoot, name: "link", destination: targetDir)

        let loader = DirectoryLoader()
        let items = try await loader.list(at: link, showHidden: false)

        XCTAssertEqual(items.count, 2)
        for item in items {
            XCTAssertEqual(
                item.url.deletingLastPathComponent().path,
                link.path,
                "자식 URL이 타겟 경로로 바뀌면 트리 인덱스/주소창 표기가 갈라진다: \(item.url.path)"
            )
        }
    }

    /// 링크가 다시 링크를 가리키는 체인도 끝까지 해석되어야 한다.
    func testList_symlinkChainToDirectory_enumeratesFinalTargetContents() async throws {
        let targetDir = try Fixture.makeDirectory(in: testRoot, name: "target")
        try Fixture.makeFile(in: targetDir, name: "inside.txt")
        let first = try Fixture.makeSymlink(in: testRoot, name: "link1", destination: targetDir)
        let second = try Fixture.makeSymlink(in: testRoot, name: "link2", destination: first)

        let loader = DirectoryLoader()
        let items = try await loader.list(at: second, showHidden: false)

        XCTAssertEqual(items.map(\.name), ["inside.txt"])
        XCTAssertEqual(items.first?.url.deletingLastPathComponent().path, second.path)
    }

    func testList_symlinkDirectoryURLItself_appliesHiddenFilter() async throws {
        let targetDir = try Fixture.makeDirectory(in: testRoot, name: "target")
        try Fixture.makeFile(in: targetDir, name: "visible.txt")
        try Fixture.makeFile(in: targetDir, name: ".hidden.txt")
        let link = try Fixture.makeSymlink(in: testRoot, name: "link", destination: targetDir)

        let loader = DirectoryLoader()
        let hiddenExcluded = try await loader.list(at: link, showHidden: false)
        XCTAssertEqual(hiddenExcluded.map(\.name), ["visible.txt"])

        let hiddenIncluded = try await loader.list(at: link, showHidden: true)
        XCTAssertEqual(hiddenIncluded.map(\.name).sorted(), [".hidden.txt", "visible.txt"])
    }

    func testListDirectories_symlinkDirectoryURLItself_returnsOnlySubdirectories() async throws {
        let targetDir = try Fixture.makeDirectory(in: testRoot, name: "target")
        try Fixture.makeFile(in: targetDir, name: "inside.txt")
        try Fixture.makeDirectory(in: targetDir, name: "nested")
        let link = try Fixture.makeSymlink(in: testRoot, name: "link", destination: targetDir)

        let loader = DirectoryLoader()
        let items = try await loader.listDirectories(at: link, showHidden: false)

        XCTAssertEqual(items.map(\.name), ["nested"])
    }

    // MARK: - 심볼릭 링크 엣지 케이스 (해석이 실패하는 경우)

    /// 링크를 해석해도 폴더가 아니면 기존 에러 매핑을 그대로 유지해야 한다.
    func testList_symlinkToFileURLItself_stillThrowsNotADirectory() async throws {
        let targetFile = try Fixture.makeFile(in: testRoot, name: "target.txt")
        let link = try Fixture.makeSymlink(in: testRoot, name: "link.txt", destination: targetFile)

        let loader = DirectoryLoader()
        do {
            _ = try await loader.list(at: link, showHidden: false)
            XCTFail("파일을 가리키는 심볼릭 링크 열거가 실패하지 않음")
        } catch let error as DirectoryError {
            XCTAssertEqual(error, .notADirectory)
        }
    }

    /// 타겟이 없는 깨진 링크: `.notFound`로 떨어지고 행/크래시가 없어야 한다.
    func testList_brokenSymlink_throwsNotFoundWithoutHanging() async throws {
        let missingTarget = testRoot.appendingPathComponent("gone", isDirectory: true)
        let link = try Fixture.makeSymlink(in: testRoot, name: "broken", destination: missingTarget)

        let loader = DirectoryLoader()
        do {
            _ = try await loader.list(at: link, showHidden: false)
            XCTFail("깨진 심볼릭 링크 열거가 실패하지 않음")
        } catch let error as DirectoryError {
            XCTAssertEqual(error, .notFound)
        }
    }

    /// 서로를 가리키는 순환 링크(ELOOP): 무한 루프 없이 `.notFound`로 떨어져야 한다.
    func testList_cyclicSymlink_throwsWithoutHanging() async throws {
        let a = testRoot.appendingPathComponent("cycleA")
        let b = testRoot.appendingPathComponent("cycleB")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)

        let loader = DirectoryLoader()
        let expectation = expectation(description: "순환 링크 열거가 유한 시간 내 종료됨")
        Task {
            do {
                _ = try await loader.list(at: a, showHidden: false)
                XCTFail("순환 심볼릭 링크 열거가 실패하지 않음")
            } catch let error as DirectoryError {
                XCTAssertEqual(error, .notFound)
            } catch {
                XCTFail("예상치 못한 에러: \(error)")
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 10.0)
    }

    /// 자기 자신을 가리키는 링크(직접 순환)도 같은 규칙.
    func testList_selfReferencingSymlink_throwsWithoutHanging() async throws {
        let selfLink = testRoot.appendingPathComponent("selfLink")
        try FileManager.default.createSymbolicLink(at: selfLink, withDestinationURL: selfLink)

        let loader = DirectoryLoader()
        let expectation = expectation(description: "자기 참조 링크 열거가 유한 시간 내 종료됨")
        Task {
            do {
                _ = try await loader.list(at: selfLink, showHidden: false)
                XCTFail("자기 참조 심볼릭 링크 열거가 실패하지 않음")
            } catch is DirectoryError {
                // 기대한 경로 (에러 종류는 커널 응답에 위임)
            } catch {
                XCTFail("예상치 못한 에러: \(error)")
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 10.0)
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
