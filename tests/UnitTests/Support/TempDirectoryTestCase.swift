import XCTest

/// 파괴적 작업(파일 생성/삭제/권한 변경)을 수행하는 모든 테스트의 베이스 클래스.
/// 테스트계획서(unifinder-mvp-test.md) §1 원칙 1 — 파괴적 작업 격리:
/// `FileManager.temporaryDirectory` 하위 전용 루트에서만 수행하며, 셋업에서 경로 prefix를 assert한다.
class TempDirectoryTestCase: XCTestCase {

    /// 이 테스트 케이스 전용 임시 루트. 매 테스트마다 새 UUID 하위 디렉토리를 생성한다.
    private(set) var testRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniFinderTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 의도적으로 realpath 정규화를 하지 않는다: `NavigationModel.normalize()`와
        // `TreeModel.canonicalDirectoryURL()`은 `standardizedFileURL`을 사용하는데, 이는
        // 존재하는 경로에 한해 `/private/var` -> `/var` 접두사를 자동으로 축약한다(Foundation
        // `stringByStandardizingPath` 표준 동작). `FileManager.default.temporaryDirectory`가
        // 돌려주는 경로는 이미 `/var` 형태이므로, 여기서 다시 정규화하면 오히려 프로덕션 코드가
        // 만드는 URL 표기와 어긋난다. `DirectoryLoader`도 자식 URL을 만들 때 호출자가 넘긴
        // 부모 URL 표기를 그대로 보존하므로, 테스트 전체에서 이 원본 표기를 일관되게 사용한다.
        testRoot = base

        try assertRootIsUnderTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let testRoot {
            // chmod 000 등으로 잠긴 하위 항목이 있을 수 있으므로 복구 후 삭제 시도.
            restorePermissionsRecursively(at: testRoot)
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
        try super.tearDownWithError()
    }

    /// 파괴적 작업 격리 원칙 위반 시 즉시 실패시키기 위한 가드.
    private func assertRootIsUnderTemporaryDirectory() throws {
        let tmpPrefix = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let rootPath = testRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        XCTAssertTrue(
            rootPath.hasPrefix(tmpPrefix),
            "테스트 루트(\(rootPath))가 임시 디렉토리(\(tmpPrefix)) 하위가 아닙니다 — 파괴적 작업 격리 원칙 위반"
        )
    }

    private func restorePermissionsRecursively(at url: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return }

        // chmod 000으로 잠긴 디렉토리는 내부를 열거할 수 없으므로, 최소한 자기 자신은 복구한다.
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        for case let child as URL in enumerator {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: child.path, isDirectory: &isDir)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)
            if isDir.boolValue {
                restorePermissionsRecursively(at: child)
            }
        }
    }
}
