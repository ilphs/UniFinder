import XCTest
@testable import UniFinder

/// `[FileItem].sorted(by:)` 순수 정렬 로직 테스트 (I/O 없이 결정적).
/// 대상: SortKey 4종(name/date/kind/size) × 오름/내림, 폴더 우선.
final class FileItemSortTests: XCTestCase {

    private func file(
        name: String,
        isDirectory: Bool = false,
        size: Int64? = 0,
        modifiedAt: Date? = Fixture.fixedDate(),
        typeDescription: String = "Text"
    ) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: isDirectory,
            isHidden: false,
            isSymlink: false,
            size: isDirectory ? nil : size,
            modifiedAt: modifiedAt,
            typeDescription: typeDescription
        )
    }

    // MARK: - 폴더 우선

    func testFoldersAlwaysSortBeforeFiles_regardlessOfKey() {
        let items = [
            file(name: "b_file.txt", size: 100),
            file(name: "a_folder", isDirectory: true),
            file(name: "a_file.txt", size: 1),
            file(name: "z_folder", isDirectory: true),
        ]

        for key in SortKey.allCases {
            for ascending in [true, false] {
                let sorted = items.sorted(by: FileSortDescriptor(key: key, ascending: ascending))
                XCTAssertTrue(sorted[0].isDirectory, "key=\(key) asc=\(ascending): 첫 항목은 폴더여야 함")
                XCTAssertTrue(sorted[1].isDirectory, "key=\(key) asc=\(ascending): 두번째 항목도 폴더여야 함")
                XCTAssertFalse(sorted[2].isDirectory)
                XCTAssertFalse(sorted[3].isDirectory)
            }
        }
    }

    // MARK: - name

    func testSortByName_ascending_usesLocalizedStandardCompare() {
        let items = [
            file(name: "img10.png"),
            file(name: "img2.png"),
            file(name: "img1.png"),
        ]
        let sorted = items.sorted(by: FileSortDescriptor(key: .name, ascending: true))
        // localizedStandardCompare는 숫자를 자연어 순서로 비교(img2 < img10)
        XCTAssertEqual(sorted.map(\.name), ["img1.png", "img2.png", "img10.png"])
    }

    func testSortByName_descending() {
        let items = [file(name: "a.txt"), file(name: "c.txt"), file(name: "b.txt")]
        let sorted = items.sorted(by: FileSortDescriptor(key: .name, ascending: false))
        XCTAssertEqual(sorted.map(\.name), ["c.txt", "b.txt", "a.txt"])
    }

    // MARK: - date

    func testSortByDate_ascendingAndDescending() {
        let items = [
            file(name: "middle", modifiedAt: Fixture.fixedDate(offset: 100)),
            file(name: "oldest", modifiedAt: Fixture.fixedDate(offset: 0)),
            file(name: "newest", modifiedAt: Fixture.fixedDate(offset: 200)),
        ]
        let asc = items.sorted(by: FileSortDescriptor(key: .date, ascending: true))
        XCTAssertEqual(asc.map(\.name), ["oldest", "middle", "newest"])

        let desc = items.sorted(by: FileSortDescriptor(key: .date, ascending: false))
        XCTAssertEqual(desc.map(\.name), ["newest", "middle", "oldest"])
    }

    // MARK: - kind

    func testSortByKind_ascendingAndDescending() {
        let items = [
            file(name: "b", typeDescription: "Markdown"),
            file(name: "a", typeDescription: "Swift"),
            file(name: "c", typeDescription: "Image"),
        ]
        let asc = items.sorted(by: FileSortDescriptor(key: .kind, ascending: true))
        XCTAssertEqual(asc.map(\.typeDescription), ["Image", "Markdown", "Swift"])

        let desc = items.sorted(by: FileSortDescriptor(key: .kind, ascending: false))
        XCTAssertEqual(desc.map(\.typeDescription), ["Swift", "Markdown", "Image"])
    }

    // MARK: - size

    func testSortBySize_ascendingAndDescending() {
        let items = [
            file(name: "medium", size: 500),
            file(name: "small", size: 10),
            file(name: "large", size: 9999),
        ]
        let asc = items.sorted(by: FileSortDescriptor(key: .size, ascending: true))
        XCTAssertEqual(asc.map(\.name), ["small", "medium", "large"])

        let desc = items.sorted(by: FileSortDescriptor(key: .size, ascending: false))
        XCTAssertEqual(desc.map(\.name), ["large", "medium", "small"])
    }

    func testSortBySize_withNilSizeFolders_doesNotCrashAndStaysFirst() {
        let items = [
            file(name: "file", size: 50),
            file(name: "folder", isDirectory: true),
        ]
        let sorted = items.sorted(by: FileSortDescriptor(key: .size, ascending: true))
        XCTAssertEqual(sorted.map(\.name), ["folder", "file"])
    }

    // MARK: - 안정성/엣지

    func testSort_emptyArray_returnsEmpty() {
        let sorted = [FileItem]().sorted(by: FileSortDescriptor(key: .name, ascending: true))
        XCTAssertTrue(sorted.isEmpty)
    }

    func testSort_singleItem_returnsSameItem() {
        let items = [file(name: "only.txt")]
        let sorted = items.sorted(by: FileSortDescriptor(key: .name, ascending: true))
        XCTAssertEqual(sorted, items)
    }
}
