import XCTest
@testable import UniFinder

/// **심볼릭 링크 미해석 회귀 봉인** (후속 T5 / D3 / 설계서 §6 규약).
///
/// 이 규약은 실수로 되돌리기 아주 쉽다 — 코드베이스에는 이미 링크를 **해석하는** 경로가 있고
/// (`AppModel.resolveTarget(of:)`, `open`, `Open in New Window`), Get Info를 만들면서 "일관성"을
/// 이유로 같은 함수를 쓰고 싶어진다. 그렇게 하면 링크 파일의 정보를 물은 사용자에게 타겟의
/// 크기·날짜를 답하게 된다. 다른 질문에 대한 답이다.
///
/// 규약: **`Open`은 의도라서 해석하고, `Get Info`는 관찰이라서 해석하지 않는다.**
@MainActor
final class InfoTargetSymlinkTests: TempDirectoryTestCase {

    func testInfoTarget_doesNotResolveSymlink() throws {
        let target = try Fixture.makeFile(in: testRoot, name: "target.txt")
        let link = try Fixture.makeSymlink(in: testRoot, name: "link.txt", destination: target)

        let info = InfoTarget(url: link)

        XCTAssertEqual(
            info.url.lastPathComponent, "link.txt",
            "InfoTarget이 링크를 해석했다 — 링크 자체의 메타데이터를 볼 수 없게 된다(D3)"
        )
        XCTAssertNotEqual(info.url.path, target.path)
    }

    /// 링크 **폴더**도 마찬가지다. `Open in New Window`는 타겟으로 가지만 Get Info는 링크를 본다.
    func testInfoTarget_doesNotResolveDirectorySymlink() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "real")
        let link = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: folder)

        XCTAssertEqual(InfoTarget(url: link).url.lastPathComponent, "alias")
    }

    /// 표기 정리(`standardizedFileURL`)는 한다 — 그것은 링크 해석이 아니다.
    func testInfoTarget_standardizesPathNotation() {
        let messy = URL(fileURLWithPath: "/tmp/./a/../b/c.txt")

        XCTAssertEqual(InfoTarget(url: messy).url.path, "/tmp/b/c.txt")
    }

    /// **같은 URL이면 같은 값** — `WindowGroup(for:)`이 창을 재사용하는 근거다(D7).
    /// `WindowSeed`가 UUID를 들고 매번 다른 값이 되는 것과 정반대 선택이다.
    func testInfoTarget_sameURLProducesEqualValues() {
        let url = URL(fileURLWithPath: "/tmp/a.txt")

        XCTAssertEqual(InfoTarget(url: url), InfoTarget(url: url))
        XCTAssertEqual(InfoTarget(url: url).hashValue, InfoTarget(url: url).hashValue)
        // 대비: 시드는 같은 폴더라도 매번 달라야 새 창이 열린다.
        XCTAssertNotEqual(WindowSeed(folderURL: url), WindowSeed(folderURL: url))
    }

    func testInfoTarget_isCodableRoundTrip() throws {
        let original = InfoTarget(url: URL(fileURLWithPath: "/tmp/a.txt"))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InfoTarget.self, from: data)

        XCTAssertEqual(decoded, original, "씬 값은 Codable이어야 창 복원이 성립한다")
    }

    /// `ItemInfoModel`이 링크 자체의 메타데이터를 읽는지 — 값 수준의 최종 확인.
    func testItemInfoModel_readsLinkItselfNotTarget() throws {
        let target = try Fixture.makeFile(in: testRoot, name: "big.bin", sizeBytes: 4096)
        let link = try Fixture.makeSymlink(in: testRoot, name: "small-link", destination: target)

        guard case let .success(attributes) = ItemInfoModel.read(link) else {
            return XCTFail("링크를 읽지 못했다")
        }

        XCTAssertTrue(attributes.isSymbolicLink)
        XCTAssertNotEqual(attributes.byteSize, 4096, "타겟의 크기를 읽고 있다 — lstat 의미론이 깨졌다")
        XCTAssertEqual(attributes.symbolicLinkDestination, target.standardizedFileURL.path)
    }

    /// **소스 수준 봉인**: Get Info 경로가 `resolveTarget`/`resolvingSymlinksInPath`를 부르지 않는다.
    func testGetInfoSources_doNotResolveSymlinks() throws {
        let sources = ProjectManifest.repositoryRoot.appendingPathComponent("src")
        let files = [
            sources.appendingPathComponent("App/InfoTarget.swift"),
            sources.appendingPathComponent("ViewModels/ItemInfoModel.swift"),
        ]

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // 주석에서는 두 이름을 언급한다(규약을 설명하기 위해). 실제 호출만 잡는다.
            let calls = text
                .components(separatedBy: .newlines)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { return false }
                    return trimmed.contains("resolveTarget(") || trimmed.contains("resolvingSymlinksInPath()")
                }

            XCTAssertTrue(
                calls.isEmpty,
                "\(file.lastPathComponent)가 링크를 해석하고 있다(D3 위반): \(calls)"
            )
        }
    }

    /// 대비 확인 — `AppModel.resolveTarget`은 **여전히 해석해야 한다**(Open 경로의 규약).
    /// 이 단언이 깨지면 심볼릭 링크 폴더를 열 수 없게 된다.
    func testResolveTarget_stillResolvesForOpenPath() throws {
        let folder = try Fixture.makeDirectory(in: testRoot, name: "real")
        let link = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: folder)
        let item = FileItem(
            url: link,
            name: "alias",
            isDirectory: true,
            isHidden: false,
            isSymlink: true,
            size: nil,
            modifiedAt: nil,
            typeDescription: "Folder"
        )

        XCTAssertEqual(
            AppModel.resolveTarget(of: item).standardizedFileURL.path,
            folder.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }
}
