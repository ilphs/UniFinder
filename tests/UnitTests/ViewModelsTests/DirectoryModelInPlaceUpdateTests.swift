import XCTest
@testable import UniFinder

/// M3 T0 — FSEvents in-place 갱신 API 단위 테스트 (m3-impl B5·B6).
///
/// 실제 프로덕션 계약(`src/ViewModels/DirectoryModel.swift`, ralph 구현):
/// `DirectoryModel.applyExternalUpdate(_ newItems: [FileItem])`
/// - `items`를 한 번에 새 배열로 교체한다(`load()`처럼 먼저 `[]`로 비우지 않는다 — 빈 화면 깜빡임 금지).
/// - 내용이 이전과 완전히 같으면(`newItems == items`) 아무 것도 하지 않는다(멱등 — B7, 자기 조작이
///   유발한 FSEvent가 겹쳐도 중복 갱신이 화면에 보이지 않는다).
/// - `selection`은 새 목록에 존재하는 URL만 남긴다(삭제된 항목만 해제, 나머지는 유지).
/// - `pendingSelectionKeys`(조작 결과 선택 대기열)를 **건드리지 않는다** — 진행 중인
///   `reload(selecting:)`의 선택 예약이 중간에 끼어든 외부 갱신으로 사라지면 안 된다(B6).
/// - `revision`이 아니라 별도의 `contentsRevision`을 증가시킨다 — 브릿지가 이를
///   `.directoryChanged`가 아닌 `.contentsUpdated`로 분류해 스크롤 초기화/첫 행 강제 선택을
///   하지 않는다(브릿지 쪽 계약은 `FileListBridgeContentsUpdatedReloadReasonTests`에서 다룬다).
@MainActor
final class DirectoryModelInPlaceUpdateTests: XCTestCase {

    private let dirURL = URL(fileURLWithPath: "/tmp/inPlaceUpdateDir")

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

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 선택 유지: 삭제된 항목만 해제, 나머지는 유지

    func testApplyExternalUpdate_keepsSelectionForSurvivingItems_dropsSelectionForRemovedOnes() async throws {
        let mock = MockDirectoryListing()
        let a = item("a.txt")
        let b = item("b.txt")
        let c = item("c.txt")
        await mock.configure(url: dirURL, items: [a, b, c])
        let model = DirectoryModel(loader: mock)
        model.load(url: dirURL)
        await waitUntil { !model.items.isEmpty }
        model.selection = [a.url, b.url]

        // b가 외부에서 삭제된 상황을 흉내낸다(FSEvents 갱신 결과에 b가 없음).
        model.applyExternalUpdate([a, c])

        XCTAssertEqual(model.selection, [a.url], "삭제된 항목(b)만 선택 해제되고 나머지(a)는 유지되어야 함(B5)")
        XCTAssertEqual(Set(model.items.map(\.url)), [a.url, c.url])
    }

    /// 항목 1개 추가 + 1개 삭제로 count가 동일한 경우에도 반영되어야 한다(B5 수용 기준).
    func testApplyExternalUpdate_reflectsChange_evenWhenItemCountStaysTheSame() async throws {
        let mock = MockDirectoryListing()
        let a = item("a.txt")
        let b = item("b.txt")
        await mock.configure(url: dirURL, items: [a, b])
        let model = DirectoryModel(loader: mock)
        model.load(url: dirURL)
        await waitUntil { !model.items.isEmpty }
        XCTAssertEqual(model.items.count, 2)

        // b 삭제 + c 생성 — count는 그대로 2.
        let c = item("c.txt")
        model.applyExternalUpdate([a, c])

        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(Set(model.items.map(\.name)), ["a.txt", "c.txt"], "count가 같아도 내용 변경이 반영되어야 함(B5)")
    }

    /// 빈 화면 깜빡임 금지 — 호출 도중(동기 실행 구간) `items`가 빈 배열을 거치면 안 된다.
    /// `applyExternalUpdate`가 `load()`처럼 `items = []`를 먼저 실행하면 이 흐름 자체가
    /// 통째로 동기이므로 테스트에서 관측할 기회가 없지만, 최소한 **호출 직후**에는 새 목록이
    /// 이미 반영되어 있어야 한다(비동기 재열거를 거치지 않는 API라는 계약을 고정한다).
    func testApplyExternalUpdate_reflectsNewItemsSynchronously_noAsyncRoundTrip() {
        let model = DirectoryModel(loader: MockDirectoryListing())
        let a = item("a.txt")

        model.applyExternalUpdate([a])

        XCTAssertEqual(model.items.map(\.url), [a.url], "in-place 갱신은 비동기 재열거 없이 즉시 반영되어야 함")
    }

    // MARK: - contentsRevision: 브릿지가 reloadData를 하도록 증가, revision(전체 이동)은 그대로

    func testApplyExternalUpdate_incrementsContentsRevision_butNotRevision() {
        let model = DirectoryModel(loader: MockDirectoryListing())
        let revisionBefore = model.revision
        let contentsRevisionBefore = model.contentsRevision

        model.applyExternalUpdate([item("a.txt")])

        XCTAssertGreaterThan(
            model.contentsRevision, contentsRevisionBefore,
            "contentsRevision이 증가하지 않으면 브릿지가 외부 변경을 reloadData하지 않는다"
        )
        XCTAssertEqual(
            model.revision, revisionBefore,
            "revision까지 올리면 브릿지가 .directoryChanged로 오판해 스크롤을 초기화한다(B5 위반)"
        )
    }

    /// 내용이 완전히 같으면 아무 신호도 내지 않는다(B7 — 자기 조작 FSEvent의 멱등 흡수).
    func testApplyExternalUpdate_withIdenticalContents_isNoOp() {
        let model = DirectoryModel(loader: MockDirectoryListing())
        let a = item("a.txt")
        model.applyExternalUpdate([a])
        let contentsRevisionAfterFirst = model.contentsRevision

        model.applyExternalUpdate([a])

        XCTAssertEqual(
            model.contentsRevision, contentsRevisionAfterFirst,
            "내용이 같은 재적용은 신호를 내면 안 된다(멱등 — 중복 reloadData 방지)"
        )
    }

    // MARK: - B6: 조작 직후 FSEvent가 결과 선택을 지우지 않음

    /// `reload(selecting:)`이 아직 완료되지 않은 상태에서 외부 변경(FSEvents)이 끼어들어도,
    /// `reload(selecting:)`이 예약해둔 선택은 살아남아야 한다.
    func testApplyExternalUpdate_duringPendingReloadSelecting_doesNotStealThePendingSelection() async throws {
        let mock = MockDirectoryListing()
        let a = item("a.txt")
        await mock.configure(url: dirURL, items: [a])
        let model = DirectoryModel(loader: mock)
        model.load(url: dirURL)
        await waitUntil { !model.items.isEmpty }

        // 붙여넣기 시나리오: 재열거 결과에 pasted가 포함되도록 미리 설정해두고, 그 재열거를
        // 게이트로 붙잡아 "아직 완료 전" 상태를 만든다.
        let pasted = item("pasted.txt")
        await mock.configure(url: dirURL, items: [a, pasted])
        await mock.hold(url: dirURL)

        model.reload(selecting: [pasted.url])
        // reload(selecting:)가 시작한 재열거가 게이트에 걸려 아직 끝나지 않은 상태.

        // 그 사이 FSEvents 갱신이 도착했다고 가정 — 이 시점 결과에는 아직 pasted가 없다(경쟁 상황 재현).
        model.applyExternalUpdate([a])
        XCTAssertTrue(model.selection.isEmpty || model.selection == [a.url], "외부 갱신 시점엔 pasted를 알 수 없으므로 아직 선택되지 않아도 됨")

        await mock.openGate(for: dirURL)
        await waitUntil { model.selection.contains(pasted.url) }

        XCTAssertEqual(
            model.selection, [pasted.url],
            "조작 직후 FSEvent가 reload(selecting:)의 예약된 선택을 지우면 안 된다(B6)"
        )
    }
}
