import XCTest
@testable import UniFinder

/// 위험 대상 가드 (m2-impl T0 "위험 대상 가드", T7 수용 기준) — ralph 작성.
///
/// 즐겨찾기 섹션 항목·볼륨 루트·홈 루트에서는 삭제/이름 변경이 막혀야 한다.
/// 트리 메뉴 비활성(`TreeModel.isProtectedNode`)과 서비스 레벨 거부(`FileOperations`)를
/// 이중으로 확인한다 — 메뉴만 막으면 단축키 경로로 새어 나간다.
///
/// **테스트 안전성** (M2 재리뷰 지적): 예전 버전은 `FileOperations()`(기본 생성자 = 실제 홈)로
/// 진짜 홈 디렉터리에 `trash`/`rename`을 걸었다. 가드가 회귀하면 테스트 실행 자체가 개발 머신의
/// 홈을 휴지통으로 보낸다. 이제 `FileOperations(homeDirectory:)`로 임시 폴더를 홈으로 주입해
/// **같은 코드 경로를 임시 디렉터리 안에서만** 검증한다(테스트계획서 §1 원칙 1 — 파괴적 작업 격리).
/// 이 파일에는 `FileManager.homeDirectoryForCurrentUser`를 조작 대상으로 넘기는 코드가 없어야 한다.
final class M2ProtectedTargetTests: TempDirectoryTestCase {

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 임시 루트 안에 "홈 루트" 역할을 할 폴더와, 그 안에 사라지면 안 되는 파일을 만든다.
    private func makeFakeHome() throws -> (home: URL, keep: URL, operations: FileOperations) {
        let home = try Fixture.makeDirectory(in: testRoot, name: "fake-home")
        let keep = try Fixture.makeFile(in: home, name: "keep.txt")
        return (home, keep, FileOperations(homeDirectory: home))
    }

    // MARK: - 서비스 레벨 (단축키/프로그램 경로까지 막히는가)

    func testTrash_homeRoot_isRejectedAsProtectedTarget() async throws {
        let (home, keep, operations) = try makeFakeHome()

        let result = await operations.trash(items: [home])

        XCTAssertEqual(result.failures.first?.error, .protectedTarget, "홈 루트 삭제가 서비스에서 막히지 않음")
        XCTAssertTrue(result.produced.isEmpty)
        XCTAssertTrue(exists(home), "홈 루트가 휴지통으로 갔다 — 데이터 손실")
        XCTAssertTrue(exists(keep), "홈 루트 내용까지 함께 사라졌다")
    }

    /// 볼륨 루트 판정은 경로 문자열(`"/"`)만 보고 파일시스템을 건드리기 전에 끝난다.
    /// 홈 루트와 달리 OS 자체가 볼륨 루트 이동/휴지통행을 허용하지 않으므로 이 케이스는
    /// 가드가 회귀해도 실제 삭제로 이어지지 않는다(그래도 실패는 즉시 드러난다).
    func testTrash_volumeRoot_isRejectedAsProtectedTarget() async throws {
        let (_, _, operations) = try makeFakeHome()
        let root = URL(fileURLWithPath: "/")

        let result = await operations.trash(items: [root])

        XCTAssertEqual(result.failures.first?.error, .protectedTarget, "볼륨 루트 삭제가 서비스에서 막히지 않음")
        XCTAssertTrue(result.produced.isEmpty)
    }

    func testRename_homeRoot_isRejectedAsProtectedTarget() async throws {
        let (home, keep, operations) = try makeFakeHome()

        let result = await operations.rename(item: home, to: "renamed-home")

        XCTAssertEqual(result.failures.first?.error, .protectedTarget)
        XCTAssertTrue(exists(home), "홈 루트 이름이 바뀌었다")
        XCTAssertTrue(exists(keep))
        XCTAssertFalse(exists(testRoot.appendingPathComponent("renamed-home")))
    }

    /// **firmlink 별칭 우회** (M2 재리뷰 blocker 2): macOS에서 `/Users/admin`과
    /// `/System/Volumes/Data/Users/admin`은 같은 디렉터리인데 경로 문자열은 완전히 다르다.
    /// 여기서는 중간 경로 요소를 심볼릭 링크로 만들어 같은 상황(표기만 다른 같은 디렉터리)을 재현한다.
    /// 문자열 비교만 하는 가드는 이 별칭 경로를 "다른 폴더"로 오판해 홈 루트를 지운다.
    func testTrash_homeRootReachedThroughAliasPath_isStillProtected() async throws {
        let real = try Fixture.makeDirectory(in: testRoot, name: "real")
        let home = try Fixture.makeDirectory(in: real, name: "fake-home")
        let keep = try Fixture.makeFile(in: home, name: "keep.txt")
        // 중간 요소가 심볼릭 링크인 별칭 경로: <testRoot>/alias/fake-home == <testRoot>/real/fake-home
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: real)
        let aliasedHome = alias.appendingPathComponent("fake-home", isDirectory: true)
        XCTAssertNotEqual(PathKey.key(aliasedHome), PathKey.key(home), "별칭 경로가 문자열로 구분되지 않으면 이 테스트는 무의미하다")

        let operations = FileOperations(homeDirectory: home)
        let result = await operations.trash(items: [aliasedHome])

        XCTAssertEqual(result.failures.first?.error, .protectedTarget, "별칭 경로로 홈 루트 가드가 뚫렸다(blocker 2)")
        XCTAssertTrue(result.produced.isEmpty)
        XCTAssertTrue(exists(home), "홈 루트가 별칭 경로를 통해 휴지통으로 갔다 — 데이터 손실(blocker 2)")
        XCTAssertTrue(exists(keep))
    }

    func testRename_homeRootReachedThroughAliasPath_isStillProtected() async throws {
        let real = try Fixture.makeDirectory(in: testRoot, name: "real")
        let home = try Fixture.makeDirectory(in: real, name: "fake-home")
        let keep = try Fixture.makeFile(in: home, name: "keep.txt")
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: real)
        let aliasedHome = alias.appendingPathComponent("fake-home", isDirectory: true)

        let operations = FileOperations(homeDirectory: home)
        let result = await operations.rename(item: aliasedHome, to: "renamed-home")

        XCTAssertEqual(result.failures.first?.error, .protectedTarget, "별칭 경로로 이름 변경 가드가 뚫렸다(blocker 2)")
        XCTAssertTrue(exists(home), "홈 루트가 별칭 경로를 통해 이름이 바뀌었다(blocker 2)")
        XCTAssertTrue(exists(keep))
        XCTAssertFalse(exists(real.appendingPathComponent("renamed-home")))
    }

    /// 별칭 경로로 도달한 홈 루트를 **이동**(잘라내기 → 붙여넣기)하는 경로도 같은 판정을 공유해야 한다.
    func testMove_homeRootReachedThroughAliasPath_isStillProtected() async throws {
        let real = try Fixture.makeDirectory(in: testRoot, name: "real")
        let home = try Fixture.makeDirectory(in: real, name: "fake-home")
        let keep = try Fixture.makeFile(in: home, name: "keep.txt")
        let alias = try Fixture.makeSymlink(in: testRoot, name: "alias", destination: real)
        let aliasedHome = alias.appendingPathComponent("fake-home", isDirectory: true)
        let destination = try Fixture.makeDirectory(in: testRoot, name: "dest")

        let operations = FileOperations(homeDirectory: home)
        let result = await operations.move(
            items: [aliasedHome],
            to: destination,
            resolver: MockConflictResolver(scripted: [], fallback: .skip)
        )

        XCTAssertEqual(result.failures.first?.error, .protectedTarget, "별칭 경로로 이동 가드가 뚫렸다(blocker 2)")
        XCTAssertTrue(exists(keep), "홈 루트가 통째로 이동됐다 — 데이터 손실(blocker 2)")
        XCTAssertFalse(exists(destination.appendingPathComponent("fake-home")))
    }

    func testTrash_ordinaryTempItem_isNotProtected() async throws {
        let (_, _, operations) = try makeFakeHome()
        let file = try Fixture.makeFile(in: testRoot, name: "ordinary.txt")

        let result = await operations.trash(items: [file])

        XCTAssertTrue(result.failures.isEmpty, "일반 항목까지 보호 대상으로 오판하면 안 됨: \(result.failures)")
    }

    /// 홈 **하위** 항목은 보호 대상이 아니다 — 가드를 조상까지 넓혀 정상 조작을 막지 않았는지 확인.
    func testTrash_itemInsideHome_isNotProtected() async throws {
        let (home, _, operations) = try makeFakeHome()
        let child = try Fixture.makeFile(in: home, name: "child.txt")

        let result = await operations.trash(items: [child])

        XCTAssertTrue(result.failures.isEmpty, "홈 하위 항목까지 막으면 안 됨: \(result.failures)")
        XCTAssertFalse(exists(child))
    }

    // MARK: - 트리 메뉴 활성 조건

    @MainActor
    func testTreeModel_sectionRootNodes_areProtected() async throws {
        let child = try Fixture.makeDirectory(in: testRoot, name: "child")
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)

        guard let homeRoot = model.node(for: testRoot) else {
            return XCTFail("홈 루트 노드를 찾을 수 없음")
        }
        XCTAssertTrue(model.isProtectedNode(homeRoot), "홈 루트는 삭제/이름변경 비활성 대상")

        await model.expand(homeRoot)
        guard let childNode = model.node(for: child) else {
            return XCTFail("자식 노드를 찾을 수 없음")
        }
        XCTAssertFalse(model.isProtectedNode(childNode), "일반 하위 폴더는 삭제/이름변경 가능해야 함")
    }

    @MainActor
    func testTreeModel_volumeRootNode_isProtected() throws {
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot)
        guard let volumeRoot = model.node(for: URL(fileURLWithPath: "/")) else {
            throw XCTSkip("이 환경에서 볼륨 섹션에 루트 노드가 없음")
        }
        XCTAssertTrue(model.isProtectedNode(volumeRoot))
    }
}
