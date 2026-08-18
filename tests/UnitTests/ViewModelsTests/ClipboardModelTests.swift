import AppKit
import XCTest
@testable import UniFinder

/// `ClipboardModel` (m2-impl.md T3, architect B6, `src/ViewModels/ClipboardModel.swift`) 단위 테스트.
///
/// 시스템 전역 클립보드를 오염시키지 않도록, 테스트마다 이름이 다른 전용 `NSPasteboard`를
/// 주입한다(M1 `loader` 주입 패턴과 동일 원칙).
@MainActor
final class ClipboardModelTests: XCTestCase {

    private func freshPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("UniFinderTest-\(UUID().uuidString)"))
    }

    private let fileA = URL(fileURLWithPath: "/tmp/clipboardA.txt")
    private let fileB = URL(fileURLWithPath: "/tmp/clipboardB.txt")

    // MARK: - copy / cut 의미론

    func testCopy_setsItemsAndOperationToCopy() {
        let model = ClipboardModel(pasteboard: freshPasteboard())
        model.copy([fileA, fileB])

        XCTAssertEqual(Set(model.items), [fileA, fileB])
        XCTAssertEqual(model.operation, .copy)
        XCTAssertTrue(model.cutURLs.isEmpty, "copy는 cut 표시 대상이 아니어야 함")
    }

    func testCut_setsItemsAndOperationToCut() {
        let model = ClipboardModel(pasteboard: freshPasteboard())
        model.cut([fileA])

        XCTAssertEqual(model.items, [fileA])
        XCTAssertEqual(model.operation, .cut)
        XCTAssertEqual(model.cutURLs, [fileA], "cut 항목은 50% 불투명 표시 대상(cutURLs)에 포함되어야 함")
    }

    func testCopy_writesFileURLsToPasteboard() {
        let pasteboard = freshPasteboard()
        let model = ClipboardModel(pasteboard: pasteboard)
        model.copy([fileA])

        let readBack = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(readBack, [fileA], "외부 앱(Finder 등)과의 상호운용을 위해 .fileURL로 기록되어야 함")
    }

    func testCut_alsoWritesToPasteboardAsPlainFileURL() {
        // 파스트보드에는 cut 의미론이 없다 — cut도 외부에는 copy로 노출된다.
        let pasteboard = freshPasteboard()
        let model = ClipboardModel(pasteboard: pasteboard)
        model.cut([fileA])

        let readBack = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(readBack, [fileA])
    }

    func testCopy_afterCut_replacesItemsAndOperation() {
        let model = ClipboardModel(pasteboard: freshPasteboard())
        model.cut([fileA])
        model.copy([fileB])

        XCTAssertEqual(model.items, [fileB])
        XCTAssertEqual(model.operation, .copy)
        XCTAssertTrue(model.cutURLs.isEmpty)
    }

    func testClear_removesOperationAndItems() {
        let model = ClipboardModel(pasteboard: freshPasteboard())
        model.cut([fileA])
        model.clear()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.operation)
        XCTAssertTrue(model.cutURLs.isEmpty)
    }

    func testRevision_incrementsOnEachStateChange() {
        let model = ClipboardModel(pasteboard: freshPasteboard())
        let initial = model.revision

        model.copy([fileA])
        XCTAssertGreaterThan(model.revision, initial, "클립보드 상태 변경은 revision을 올려야 브릿지가 reloadData를 트리거함(B6)")

        let afterCopy = model.revision
        model.clear()
        XCTAssertGreaterThan(model.revision, afterCopy)
    }

    // MARK: - 붙여넣기 소스/연산 판정

    func testPasteSource_afterCopy_returnsCopyOperation() {
        let model = ClipboardModel(pasteboard: freshPasteboard())
        model.copy([fileA])

        let source = model.pasteSource()
        XCTAssertEqual(source.operation, .copy)
        XCTAssertEqual(source.items, [fileA])
    }

    func testPasteSource_afterCut_returnsCutOperation() {
        let model = ClipboardModel(pasteboard: freshPasteboard())
        model.cut([fileA])

        let source = model.pasteSource()
        XCTAssertEqual(source.operation, .cut)
        XCTAssertEqual(source.items, [fileA])
    }

    func testCanPaste_emptyPasteboard_isFalse() {
        let model = ClipboardModel(pasteboard: freshPasteboard())
        XCTAssertFalse(model.canPaste)
    }

    func testCanPaste_afterCopy_isTrue() {
        let model = ClipboardModel(pasteboard: freshPasteboard())
        model.copy([fileA])
        XCTAssertTrue(model.canPaste)
    }

    // MARK: - 외부 변경 감지 (B6 — changeCount 비교)

    func testSyncWithPasteboard_noChange_keepsInternalState() {
        let pasteboard = freshPasteboard()
        let model = ClipboardModel(pasteboard: pasteboard)
        model.cut([fileA])

        let changed = model.syncWithPasteboard()

        XCTAssertFalse(changed, "파스트보드가 바뀌지 않았다면 상태 변경이 없어야 함")
        XCTAssertEqual(model.operation, .cut, "파스트보드가 바뀌지 않았다면 내부 cut 상태가 유지되어야 함")
        XCTAssertEqual(model.items, [fileA])
    }

    func testSyncWithPasteboard_externalWrite_clearsInternalCutState() {
        let pasteboard = freshPasteboard()
        let model = ClipboardModel(pasteboard: pasteboard)
        model.cut([fileA])

        // 외부 앱(Finder 등)이 클립보드를 바꾼 상황을 흉내: changeCount가 증가한다.
        pasteboard.clearContents()
        pasteboard.writeObjects([fileB as NSURL])

        let changed = model.syncWithPasteboard()

        XCTAssertTrue(changed)
        XCTAssertNil(model.operation, "외부에서 변경되면 내부 cut 표시가 해제되어야 함(잘못된 위치의 잘라내기 방지)")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.cutURLs.isEmpty)
    }

    func testSyncWithPasteboard_ownWrite_doesNotSelfInvalidate() {
        // model 자신이 만든 변경(copy/cut 호출)은 "외부 변경"으로 오판하면 안 된다.
        let pasteboard = freshPasteboard()
        let model = ClipboardModel(pasteboard: pasteboard)
        model.cut([fileA])

        _ = model.syncWithPasteboard()
        _ = model.syncWithPasteboard() // 반복 호출해도 자기 자신의 변경으로 해제되면 안 됨

        XCTAssertEqual(model.operation, .cut)
        XCTAssertFalse(model.ownsPasteboard == false, "자기 자신이 쓴 직후에는 파스트보드 소유권을 유지해야 함")
    }

    func testOwnsPasteboard_afterExternalWrite_isFalse() {
        let pasteboard = freshPasteboard()
        let model = ClipboardModel(pasteboard: pasteboard)
        model.copy([fileA])
        XCTAssertTrue(model.ownsPasteboard)

        pasteboard.clearContents()
        pasteboard.writeObjects([fileB as NSURL])

        XCTAssertFalse(model.ownsPasteboard, "외부에서 파스트보드를 덮어쓰면 소유권을 잃어야 함")
    }

    // MARK: - 다중 창 소유권 (다중 창 지원 — 여러 창이 같은 ClipboardModel을 공유할 때)

    /// 조건을 만족할 때까지 메인 액터를 양보하며 기다린다(FullDiskAccessModelTests와 같은 패턴).
    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 창 A·창 B가 같은 `ClipboardModel`을 공유하며 각자 다른 `owner`로
    /// `startObservingPasteboard(owner:)`를 부른 상황을 흉내낸다. 창 하나만 닫혀도
    /// (그 창의 owner만 해제) 다른 창이 아직 열려 있으므로 관측은 계속 살아 있어야 한다.
    func testStartObservingTwoOwners_thenStopOne_stillReactsToExternalChange() async {
        let pasteboard = freshPasteboard()
        let model = ClipboardModel(pasteboard: pasteboard)
        model.cut([fileA])
        let windowA = UUID()
        let windowB = UUID()

        model.startObservingPasteboard(owner: windowA)
        model.startObservingPasteboard(owner: windowB)
        model.stopObservingPasteboard(owner: windowA)

        pasteboard.clearContents()
        pasteboard.writeObjects([fileB as NSURL])
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { model.cutURLs.isEmpty }

        XCTAssertTrue(
            model.cutURLs.isEmpty,
            "두 창이 관측 중인데 한 창만 닫혔다고 관측이 죽으면 안 된다(다른 창의 외부 변경 감지가 죽는다)"
        )
    }

    /// 두 창이 각자 시작했으면 두 창이 각자 해제해야 완전히 멈춘다 — 마지막 창까지 닫힌 뒤에는 반응하지 않아야 한다.
    func testStartObservingTwoOwners_thenStopBoth_noLongerReactsToExternalChange() async {
        let pasteboard = freshPasteboard()
        let model = ClipboardModel(pasteboard: pasteboard)
        model.cut([fileA])
        let windowA = UUID()
        let windowB = UUID()

        model.startObservingPasteboard(owner: windowA)
        model.startObservingPasteboard(owner: windowB)
        model.stopObservingPasteboard(owner: windowA)
        model.stopObservingPasteboard(owner: windowB)

        pasteboard.clearContents()
        pasteboard.writeObjects([fileB as NSURL])
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(
            model.cutURLs, [fileA],
            "시작한 횟수만큼 해제됐다면 관측이 완전히 멈춰야 한다 — 그런데도 반응하면 cut 표시가 이미 닫힌 창 기준으로 계속 흔들린다"
        )
    }
}
