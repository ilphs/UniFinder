import XCTest
@testable import UniFinder

/// M3 T0 — **in-place 외부 변경 갱신** (`refreshContents`/`applyExternalUpdate`) 단위 테스트.
///
/// 계획서 B5가 지적한 핵심: 기존 `load()`/`reload()`는 시작 시 `items = []`·`selection = []`·
/// `revision &+= 1`을 수행하고, 브릿지는 `revision` 변화를 `.directoryChanged`로 해석해
/// **스크롤 최상단 이동 + 첫 행 강제 선택**까지 실행한다. FSEvents가 그 경로를 쓰면 파일이 하나
/// 바뀔 때마다 화면이 깜빡이고 스크롤이 튄다.
///
/// 그래서 이 테스트들은 "갱신이 반영되는가"뿐 아니라 **무엇을 건드리지 않는가**(revision·선택·
/// pendingSelectionKeys)를 함께 고정한다.
@MainActor
final class DirectoryModelExternalUpdateTests: XCTestCase {

    private let dirURL = URL(fileURLWithPath: "/tmp/m3-external-update")

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
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func loadedModel(items: [FileItem]) async -> (DirectoryModel, MockDirectoryListing) {
        let mock = MockDirectoryListing()
        await mock.configure(url: dirURL, items: items)
        let model = DirectoryModel(loader: mock)
        model.load(url: dirURL)
        await waitUntil { model.items.count == items.count }
        return (model, mock)
    }

    // MARK: - B5: 스크롤·선택을 건드리지 않는 갱신 신호

    /// `revision`이 오르면 브릿지가 스크롤을 최상단으로 되돌린다 — 외부 갱신은 그러면 안 된다.
    func testApplyExternalUpdate_doesNotBumpRevision_soListDoesNotScrollToTop() async {
        let (model, _) = await loadedModel(items: [item("a.txt"), item("b.txt")])
        let revisionBefore = model.revision
        let contentsBefore = model.contentsRevision

        model.applyExternalUpdate([item("a.txt"), item("b.txt"), item("c.txt")])

        XCTAssertEqual(model.revision, revisionBefore, "외부 갱신이 revision을 올리면 스크롤이 최상단으로 튄다(B5)")
        XCTAssertEqual(model.contentsRevision, contentsBefore + 1, "외부 갱신은 contentsRevision으로 신호해야 한다")
        XCTAssertEqual(model.items.count, 3)
    }

    /// **핵심 수용 기준**: 1개 추가 + 1개 삭제로 `items.count`가 동일해도 갱신이 반영되어야 한다
    /// (기존 `.itemsChanged`(개수 비교)로는 이 경우가 통째로 누락된다).
    func testApplyExternalUpdate_sameItemCountWithDifferentContents_stillSignalsUpdate() async {
        let (model, _) = await loadedModel(items: [item("a.txt"), item("b.txt")])
        let contentsBefore = model.contentsRevision

        model.applyExternalUpdate([item("a.txt"), item("c.txt")]) // b 삭제 + c 추가 → count는 그대로 2

        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.items.map(\.name), ["a.txt", "c.txt"])
        XCTAssertEqual(
            model.contentsRevision, contentsBefore + 1,
            "개수가 같다는 이유로 갱신을 건너뛰면 화면이 실제 폴더와 어긋난 채로 남는다(B5)"
        )
    }

    func testApplyExternalUpdate_keepsSelectionOfSurvivingItems_andReleasesOnlyDeletedOnes() async {
        let items = [item("a.txt"), item("b.txt"), item("c.txt")]
        let (model, _) = await loadedModel(items: items)
        model.selection = [items[0].url, items[1].url]

        // b.txt만 외부에서 삭제됨
        model.applyExternalUpdate([items[0], items[2]])

        XCTAssertEqual(model.selection, [items[0].url], "사라진 항목만 해제하고 나머지 선택은 유지해야 한다")
    }

    func testApplyExternalUpdate_withIdenticalContents_isNoOp() async {
        let items = [item("a.txt"), item("b.txt")]
        let (model, _) = await loadedModel(items: items)
        let contentsBefore = model.contentsRevision

        // 자기 조작이 유발한 FSEvent가 `applyOperationResult`의 갱신과 겹친 경우 (B7)
        model.applyExternalUpdate(items)

        XCTAssertEqual(
            model.contentsRevision, contentsBefore,
            "내용이 같은 갱신까지 신호하면 조작 1건마다 불필요한 reloadData가 두 번 돈다(B7 멱등성)"
        )
    }

    func testApplyExternalUpdate_neverClearsItemsMidway() async {
        let items = [item("a.txt"), item("b.txt")]
        let (model, _) = await loadedModel(items: items)

        model.applyExternalUpdate([items[0]])

        XCTAssertFalse(model.items.isEmpty, "외부 갱신 중 목록이 비면 빈 화면 깜빡임이 보인다(B5)")
    }

    // MARK: - refreshContents (재열거 경로)

    func testRefreshContents_reflectsNewListing_withoutBumpingRevision() async {
        let (model, mock) = await loadedModel(items: [item("a.txt")])
        let revisionBefore = model.revision
        await mock.configure(url: dirURL, items: [item("a.txt"), item("new.txt")])

        model.refreshContents()
        await waitUntil { model.items.count == 2 }

        XCTAssertEqual(model.items.map(\.name), ["a.txt", "new.txt"])
        XCTAssertEqual(model.revision, revisionBefore, "재열거 경로도 revision을 건드리면 안 된다")
    }

    /// 외부 갱신이 실패해도(권한 회수·폴더 삭제) 화면을 지우지 않는다.
    /// 폴더 소실 판정은 `DirectoryWatcher.onVanished` → `AppModel`이 담당한다(B7).
    func testRefreshContents_whenListingFails_keepsCurrentItems() async {
        let (model, mock) = await loadedModel(items: [item("a.txt")])
        await mock.configure(url: dirURL, error: .notFound)

        model.refreshContents()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(model.items.map(\.name), ["a.txt"], "열거 실패가 현재 목록을 지우면 안 된다")
        XCTAssertNil(model.error, "외부 갱신 실패를 에러 화면으로 승격시키면 안 된다")
    }

    // MARK: - B6 회귀: 조작 직후 FSEvent가 결과 선택을 지우지 않는가

    /// 재현 시나리오: 붙여넣기 → `reload(selecting:)`이 generation N을 시작한 직후, 그 붙여넣기가
    /// 유발한 FSEvent가 도착한다.
    ///
    /// FSEvents 경로가 `load()`를 재사용하면 generation N+1이 뜨면서 gen N 태스크가 폐기되는데,
    /// `pendingSelectionKeys`는 이미 gen N이 소비해 비어 있어 **선택 대상이 영영 사라진다**.
    /// in-place 경로는 세대를 올리지도, pending 키를 소비하지도 않으므로 선택이 살아남는다.
    func testExternalChangeDuringPasteReload_doesNotEatPendingSelection() async {
        let existing = item("a.txt")
        let (model, mock) = await loadedModel(items: [existing])

        let pasted = item("pasted.txt")
        await mock.configure(url: dirURL, items: [existing, pasted])

        model.reload(selecting: [pasted.url])
        // 붙여넣기가 유발한 FSEvent가 곧바로 도착한 상황
        model.refreshContents()

        await waitUntil { model.selection == [pasted.url] }
        XCTAssertEqual(
            model.selection, [pasted.url],
            "조작 결과 선택이 FSEvent 갱신에 지워졌다(B6) — FSEvents 경로가 load()를 재사용하고 있지 않은지 확인"
        )
    }

    /// 반대 방향 확인: in-place 갱신은 대기 중인 선택 요청을 **소비하지 않는다**.
    /// (소비해 버리면 뒤이어 도착하는 실제 재열거가 선택을 반영할 수 없다)
    func testRefreshContents_doesNotConsumePendingSelection() async {
        let existing = item("a.txt")
        let (model, mock) = await loadedModel(items: [existing])
        let pasted = item("pasted.txt")

        // 아직 목록에 없는 항목을 선택 대상으로 예약해 둔 상태에서 외부 갱신만 먼저 돈다.
        await mock.configure(url: dirURL, items: [existing])
        model.reload(selecting: [pasted.url])
        await waitUntil { model.items.count == 1 }

        await mock.configure(url: dirURL, items: [existing, pasted])
        model.refreshContents()
        await waitUntil { model.items.count == 2 }

        XCTAssertEqual(model.items.count, 2, "외부 갱신이 새 항목을 반영해야 한다")
    }
}
