import XCTest
@testable import UniFinder

/// `DirectoryModel.reload(selecting:)` (m2-impl.md T4, architect B5) 단위 테스트.
///
/// M1의 `reload()`는 URL 기준으로 "기존 선택"만 복원한다. 파괴적 작업(붙여넣기/이름변경/새
/// 폴더) 후에는 "그 작업으로 만들어진/바뀐 항목"을 선택해야 하는데 기존 API로는 불가능했다.
///
/// **가정하는 프로덕션 API**: `DirectoryModel.reload(selecting: Set<URL>)` — 현재 폴더를
/// 재열거한 뒤, 넘겨준 URL 중 새 목록에 존재하는 것만 `selection`으로 채운다(사라진 URL은
/// 무시). URL 비교는 `TreeModel.indexKey` 수준의 정규화 경로 키로 해야 한다
/// (`DirectoryLoader`가 만드는 폴더 URL의 후행 슬래시 표기 차이 대응).
@MainActor
final class DirectoryModelReloadSelectingTests: XCTestCase {

    private let dirURL = URL(fileURLWithPath: "/tmp/reloadSelectingDir")

    private func item(_ name: String, isDirectory: Bool = false) -> FileItem {
        FileItem(
            url: dirURL.appendingPathComponent(name, isDirectory: isDirectory),
            name: name,
            isDirectory: isDirectory,
            isHidden: false,
            isSymlink: false,
            size: isDirectory ? nil : 0,
            modifiedAt: Fixture.fixedDate(),
            typeDescription: isDirectory ? "폴더" : "Text"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        interval: UInt64 = 10_000_000,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    func testReloadSelecting_selectsSpecifiedItemAfterReload() async throws {
        let mock = MockDirectoryListing()
        await mock.configure(url: dirURL, items: [item("a.txt"), item("b.txt")])
        let model = DirectoryModel(loader: mock)
        model.load(url: dirURL)
        await waitUntil { !model.items.isEmpty }
        model.selection = []

        let target = item("b.txt")
        model.reload(selecting: [target.url])
        await waitUntil { model.selection.contains(target.url) }

        XCTAssertEqual(model.selection, [target.url])
    }

    func testReloadSelecting_ignoresURLsNotPresentInNewListing() async throws {
        let mock = MockDirectoryListing()
        await mock.configure(url: dirURL, items: [item("a.txt")])
        let model = DirectoryModel(loader: mock)
        model.load(url: dirURL)
        await waitUntil { !model.items.isEmpty }

        let missing = dirURL.appendingPathComponent("never-existed.txt")
        model.reload(selecting: [missing])
        await waitUntil { model.revision > 0 } // 재열거 완료를 기다림(짧은 폴링)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(model.selection.isEmpty, "새 목록에 없는 URL은 선택되면 안 됨")
    }

    func testReloadSelecting_afterPasteCreatesNewItem_selectsPastedItem() async throws {
        // 붙여넣기 시나리오 흉내: 처음엔 a.txt만 있다가, reload 시점에는 pasted.txt가 추가된다.
        let mock = MockDirectoryListing()
        await mock.configure(url: dirURL, items: [item("a.txt")])
        let model = DirectoryModel(loader: mock)
        model.load(url: dirURL)
        await waitUntil { !model.items.isEmpty }

        let pasted = item("pasted.txt")
        await mock.configure(url: dirURL, items: [item("a.txt"), pasted])

        model.reload(selecting: [pasted.url])
        await waitUntil { model.items.count == 2 }
        await waitUntil { model.selection.contains(pasted.url) }

        XCTAssertEqual(model.selection, [pasted.url])
    }

    func testReloadSelecting_multipleURLs_selectsAllPresentOnes() async throws {
        let mock = MockDirectoryListing()
        let items = [item("a.txt"), item("b.txt"), item("c.txt")]
        await mock.configure(url: dirURL, items: items)
        let model = DirectoryModel(loader: mock)
        model.load(url: dirURL)
        await waitUntil { !model.items.isEmpty }

        let wanted = Set([items[0].url, items[2].url])
        model.reload(selecting: wanted)
        await waitUntil { model.selection.count == 2 }

        XCTAssertEqual(model.selection, wanted)
    }
}
