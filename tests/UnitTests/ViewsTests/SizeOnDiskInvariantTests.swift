import XCTest
@testable import UniFinder

/// "Size on disk" 표시와 설계서 §3.2 불변식 3의 **정합성** (reviewer minor #9).
///
/// 코드는 파일의 on-disk 크기를 Get Info 창에 보여주는데, 설계서의 불변식 3은
/// "on-disk 크기는 표시하지 않는다"라고 적혀 있었다 — 문서와 코드가 정면으로 어긋난 상태다.
///
/// **코드를 유지하고 문서를 좁히는 쪽으로 해소했다**: 이 행은 Finder의 Get Info와 같은 정보이고,
/// 값은 `read()`가 다른 속성과 함께 이미 prefetch한 것이라 추가 비용이 없다. 불변식의 원래 취지는
/// **폴더 크기 합산의 정의**(디스크상 크기 vs 논리 크기 중 무엇을 더하는가)에 있었으므로,
/// 문구를 그 범위로 정정했다. 이 테스트는 둘이 다시 어긋나는 것을 막는다.
final class SizeOnDiskInvariantTests: XCTestCase {

    private func designDocument() throws -> String {
        try String(
            contentsOf: ProjectManifest.repositoryRoot
                .appendingPathComponent("ref-docs/specs/design/unifinder-mvp-design.md"),
            encoding: .utf8
        )
    }

    /// 불변식 3은 **폴더 크기 계산기**에 대한 규칙임을 명시한다.
    func testDesignInvariant_scopesLogicalSizeRuleToTheFolderSizeCalculator() throws {
        let document = try designDocument()

        XCTAssertTrue(
            document.contains("DirectorySizeCalculator"),
            "불변식 3이 어떤 코드에 적용되는지 말하지 않는다 — 그래서 표시 규칙으로 오독됐다"
        )
        XCTAssertFalse(
            document.contains("on-disk(할당) 크기는 표시하지 않는다"),
            "코드는 파일의 on-disk 크기를 표시한다 — 문서가 그것을 금지하는 문구로 되돌아갔다"
        )
        XCTAssertTrue(
            document.contains("Size on disk"),
            "정정된 문구가 Get Info의 표시 행을 예외로 명시해야 한다"
        )
    }

    /// 코드 쪽 계약: 파일에는 on-disk 크기를 채우고, **폴더에는 채우지 않는다**
    /// (폴더 크기는 계산기가 논리 크기로만 합산한다 — 두 정의가 한 화면에 섞이지 않는다).
    func testAttributes_carryAllocatedSizeForFilesOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("size-on-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: file)

        guard case let .success(fileAttributes) = ItemInfoModel.read(file) else {
            return XCTFail("파일 메타데이터를 읽지 못했다")
        }
        XCTAssertNotNil(fileAttributes.allocatedSize, "파일의 on-disk 크기는 표시 대상이다")

        guard case let .success(folderAttributes) = ItemInfoModel.read(root) else {
            return XCTFail("폴더 메타데이터를 읽지 못했다")
        }
        XCTAssertNil(folderAttributes.allocatedSize, "폴더에는 on-disk 크기를 채우지 않는다(불변식 1·3)")
        XCTAssertNil(folderAttributes.byteSize)
    }

    /// 표시 행 자체가 사라지지 않았는지 — 문서만 고치고 코드가 빠지면 정정의 근거가 없어진다.
    func testItemInfoWindow_stillShowsTheSizeOnDiskRow() throws {
        let source = try String(
            contentsOf: ProjectManifest.repositoryRoot
                .appendingPathComponent("src/Views/ItemInfoWindow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"row("Size on disk""#), "Get Info 창에서 on-disk 크기 행이 사라졌다")
    }
}
