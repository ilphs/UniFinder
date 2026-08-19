import XCTest
@testable import UniFinder

/// Get Info 창의 메타데이터 읽기 (후속 T5 / UI설계 §7.6).
@MainActor
final class ItemInfoModelTests: TempDirectoryTestCase {

    private func makeModel(_ url: URL) -> ItemInfoModel {
        ItemInfoModel(
            target: InfoTarget(url: url),
            // LaunchServices에 붙지 않는다(개발 머신마다 설치된 앱이 다르다).
            openWithService: OpenWithService(
                candidatesProvider: { _ in [URL(fileURLWithPath: "/Applications/Preview.app")] },
                defaultApplicationProvider: { _ in URL(fileURLWithPath: "/Applications/Preview.app") },
                contentTypeProvider: { _ in .plainText },
                launcher: { _, _, _ in },
                fileDefaultSetter: { _, _ in },
                contentTypeDefaultSetter: { _, _ in }
            )
        )
    }

    private func load(_ url: URL) async -> ItemInfoModel {
        let model = makeModel(url)
        model.load()
        await model.waitForLoad()
        return model
    }

    // MARK: - 일반 파일

    func testRegularFile_readsCoreAttributes() async throws {
        let file = try Fixture.makeFile(in: testRoot, name: "report.txt", sizeBytes: 1234)

        let model = await load(file)

        XCTAssertEqual(model.state, .loaded)
        let attributes = try XCTUnwrap(model.attributes)
        XCTAssertEqual(attributes.name, "report.txt")
        XCTAssertEqual(attributes.byteSize, 1234)
        XCTAssertEqual(attributes.isDirectory, false)
        XCTAssertEqual(attributes.isSymbolicLink, false)
        XCTAssertNil(attributes.symbolicLinkDestination)
        XCTAssertEqual(attributes.location, file.deletingLastPathComponent().path)
        XCTAssertNotNil(attributes.modifiedAt)
        XCTAssertNotNil(attributes.permissions)
        XCTAssertEqual(attributes.permissions?.count, 9, "rw-r--r-- 형식이어야 한다")
        XCTAssertNotNil(attributes.owner)
        XCTAssertEqual(attributes.typeIdentifier, "public.plain-text")
        XCTAssertEqual(model.folderSize, .notApplicable, "파일에는 폴더 크기 계산이 걸리면 안 된다")
    }

    /// 파일에는 "Open with:" 후보가 채워지고, 기본 앱이 선택돼 있어야 한다.
    func testRegularFile_loadsOpenWithCandidates() async throws {
        let file = try Fixture.makeFile(in: testRoot, name: "a.txt")

        let model = await load(file)

        XCTAssertEqual(model.applications.map(\.url.lastPathComponent), ["Preview.app"])
        XCTAssertEqual(model.selectedApplication?.lastPathComponent, "Preview.app")
    }

    /// **핵심 회귀** (reviewer major #5): LaunchServices 조회는 메인 액터 **밖**에서 돌아야 한다.
    ///
    /// `urlsForApplications(toOpen:)`/`urlForApplication(toOpen:)`은 LaunchServices DB에 물어보는
    /// 동기 IPC라, DB 재빌드 중이거나 후보 앱이 느린 볼륨에 있으면 수백 ms 이상 잡아먹는다.
    /// 메인 액터에서 부르면 그동안 앱 전체가 멈춘다(§5 "메인 블로킹 0").
    func testOpenWithCandidates_areResolvedOffTheMainActor() async throws {
        let file = try Fixture.makeFile(in: testRoot, name: "probe.txt")
        let sawMainThread = ThreadFlag()
        let model = ItemInfoModel(
            target: InfoTarget(url: file),
            openWithService: OpenWithService(
                candidatesProvider: { _ in
                    sawMainThread.recordIfMain()
                    return [URL(fileURLWithPath: "/Applications/Preview.app")]
                },
                defaultApplicationProvider: { _ in
                    sawMainThread.recordIfMain()
                    return URL(fileURLWithPath: "/Applications/Preview.app")
                },
                contentTypeProvider: { _ in .plainText },
                launcher: { _, _, _ in },
                fileDefaultSetter: { _, _ in },
                contentTypeDefaultSetter: { _, _ in }
            )
        )

        model.load()
        await model.waitForLoad()

        XCTAssertFalse(
            sawMainThread.didRunOnMain,
            "LaunchServices 조회가 메인 스레드에서 돌았다 — 느린 조회 하나가 앱 전체를 멈춘다"
        )
        XCTAssertEqual(model.applications.map(\.url.lastPathComponent), ["Preview.app"], "결과 반영은 그대로여야 한다")
        XCTAssertEqual(model.selectedApplication?.lastPathComponent, "Preview.app")
    }

    /// 조회 클로저는 백그라운드에서 불리므로 기록도 스레드 안전해야 한다.
    private final class ThreadFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func recordIfMain() {
            guard Thread.isMainThread else { return }
            lock.lock(); defer { lock.unlock() }
            flag = true
        }

        var didRunOnMain: Bool {
            lock.lock(); defer { lock.unlock() }
            return flag
        }
    }

    // MARK: - 폴더

    func testFolder_hasNilByteSizeAndStartsCalculating() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "docs")
        try Fixture.makeFile(in: folder, name: "a.txt", sizeBytes: 100)

        let model = makeModel(folder)
        model.load()
        await model.waitForLoad()

        let attributes = try XCTUnwrap(model.attributes)
        XCTAssertTrue(attributes.isDirectory)
        XCTAssertNil(attributes.byteSize, "폴더의 byteSize는 언제나 nil이다(설계서 §3.2 불변식 1)")
        XCTAssertNil(attributes.allocatedSize, "폴더의 on-disk 크기는 표시하지 않는다(불변식 3)")

        await model.waitForFolderSize()
        guard case let .done(bytes, itemCount, incomplete) = model.folderSize else {
            return XCTFail("폴더 크기 계산이 끝나지 않았다: \(model.folderSize)")
        }
        XCTAssertEqual(bytes, 100)
        XCTAssertEqual(itemCount, 1)
        XCTAssertFalse(incomplete)
    }

    /// 폴더에는 "Open with:" 섹션을 띄우지 않는다(UI설계 §7.6).
    func testFolder_hasNoOpenWithCandidates() async throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "docs")

        let model = await load(folder)

        XCTAssertTrue(model.applications.isEmpty)
        XCTAssertNil(model.selectedApplication)
    }

    // MARK: - 심볼릭 링크 (D3)

    func testSymlink_showsLinkItselfAndOriginalPath() async throws {
        let target = try Fixture.makeFile(in: testRoot, name: "target.txt", sizeBytes: 5000)
        let link = try Fixture.makeSymlink(in: testRoot, name: "shortcut.txt", destination: target)

        let model = await load(link)

        let attributes = try XCTUnwrap(model.attributes)
        XCTAssertTrue(attributes.isSymbolicLink, "링크를 해석해 버리면 isSymbolicLink가 false가 된다")
        XCTAssertNotEqual(
            attributes.byteSize, 5000,
            "링크 자체가 아니라 타겟의 크기를 보여주고 있다 — D3 위반(Get Info는 관찰이라 해석하지 않는다)"
        )
        XCTAssertEqual(
            attributes.symbolicLinkDestination,
            target.standardizedFileURL.path,
            "Original: 행에 해석된 경로를 병기해야 한다"
        )
    }

    func testSymlink_relativeDestinationIsResolvedAgainstParent() async throws {
        let target = try Fixture.makeFile(in: testRoot, name: "target.txt")
        let link = testRoot.appendingPathComponent("relative-link.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")

        let model = await load(link)

        XCTAssertEqual(model.attributes?.symbolicLinkDestination, target.standardizedFileURL.path)
    }

    // MARK: - 잠금 / 실패 경로

    func testLockedFile_isReportedAsLocked() async throws {
        let file = try Fixture.makeFile(in: testRoot, name: "locked.txt")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
        }

        let model = await load(file)

        XCTAssertEqual(model.attributes?.isLocked, true)
    }

    func testMissingURL_entersFailedState() async {
        let missing = testRoot.appendingPathComponent("does-not-exist.txt")

        let model = await load(missing)

        guard case let .failed(message) = model.state else {
            return XCTFail("존재하지 않는 대상은 실패 상태여야 한다: \(model.state)")
        }
        XCTAssertEqual(message, ItemInfoModel.ItemInfoError.notFound.message)
        XCTAssertNil(model.attributes)
    }

    // MARK: - 순수 함수

    func testPermissionString_translatesPosixModes() {
        XCTAssertEqual(ItemInfoModel.permissionString(from: 0o644), "rw-r--r--")
        XCTAssertEqual(ItemInfoModel.permissionString(from: 0o755), "rwxr-xr-x")
        XCTAssertEqual(ItemInfoModel.permissionString(from: 0o000), "---------")
        XCTAssertEqual(ItemInfoModel.permissionString(from: 0o777), "rwxrwxrwx")
    }

    /// `Size:` 행 문구 — 계산 중/완료/불완전 3상태 (UI설계 §7.6).
    func testSizeText_reflectsFolderCalculationState() {
        var attributes = ItemInfoModel.Attributes(
            name: "docs", kind: "Folder", typeIdentifier: nil, isDirectory: true, isSymbolicLink: false,
            symbolicLinkDestination: nil, location: "/tmp", byteSize: nil, allocatedSize: nil,
            createdAt: nil, modifiedAt: nil, accessedAt: nil, owner: nil, group: nil,
            permissions: nil, isLocked: false, tags: []
        )

        XCTAssertEqual(
            ItemInfoWindow.sizeText(attributes: attributes, folderSize: .calculating(bytes: 0, itemCount: 0)),
            "Calculating…"
        )
        XCTAssertTrue(
            ItemInfoWindow.sizeText(attributes: attributes, folderSize: .done(bytes: 2048, itemCount: 3, isIncomplete: false))
                .contains("3 items")
        )
        XCTAssertTrue(
            ItemInfoWindow.sizeText(attributes: attributes, folderSize: .done(bytes: 2048, itemCount: 3, isIncomplete: true))
                .contains("(some items couldn't be read)"),
            "읽지 못한 하위가 있으면 값이 어림값임을 화면에 밝혀야 한다"
        )

        attributes.isDirectory = false
        attributes.byteSize = 2_412_033
        let fileText = ItemInfoWindow.sizeText(attributes: attributes, folderSize: .notApplicable)
        XCTAssertTrue(fileText.contains("2,412,033 bytes"), "파일은 정확한 바이트 수를 병기한다: \(fileText)")
    }

    func testItemsText_singularAndPlural() {
        XCTAssertEqual(ItemInfoWindow.itemsText(1), "1 item")
        XCTAssertEqual(ItemInfoWindow.itemsText(2), "2 items")
        XCTAssertEqual(ItemInfoWindow.itemsText(1234), "1,234 items")
    }
}
