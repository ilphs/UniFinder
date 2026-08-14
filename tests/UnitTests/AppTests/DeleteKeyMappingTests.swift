import AppKit
import SwiftUI
import XCTest
@testable import UniFinder

/// 삭제 키 매핑 확정 (m2-impl.md T2, architect B2) — **회귀 방지 최우선** 테스트.
///
/// M1은 이미 `KeyScalar.backspace`(단독)를 상위 폴더 이동에 할당했다. M2는 절대 이 키를
/// 재할당하지 않고, 휴지통 이동은 `Cmd+Backspace`와 `fn+Delete`(`KeyScalar.forwardDelete`)에만
/// 할당한다. 이 파일의 `testBackspaceAlone_*`는 M1 회귀 테스트를 겸한다.
///
/// **가정하는 프로덕션 변경**: `FileListBridge`에 의미 단위 콜백 `onDelete: () -> Void`가
/// 추가되고, `Coordinator.handleKeyDown`이 `Cmd+Backspace`/`fn+Delete`에서 이를 호출한다.
@MainActor
final class DeleteKeyMappingTests: XCTestCase {

    /// `Coordinator.tableView`는 weak라서 테스트가 강한 참조를 들고 있어야 한다
    /// (임시 객체를 바로 대입하면 즉시 해제되어 키 이벤트가 브릿지에 도달하지 않는다).
    private var retainedTableViews: [KeyRoutingTableView] = []

    private func makeCoordinator(
        onNavigateUp: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {}
    ) -> FileListBridge.Coordinator {
        var selection = Set<URL>()
        let bridge = FileListBridge(
            items: [],
            revision: 0,
            sortDescriptor: .default,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusBroker: FocusBroker(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "DeleteKeyMappingTests-\(UUID().uuidString)")!),
            onOpen: { _ in },
            onNavigateUp: onNavigateUp,
            onSortChange: { _ in },
            onRefresh: {},
            onTypeAhead: { _ in },
            onDelete: onDelete
        )
        let coordinator = bridge.makeCoordinator()
        let tableView = KeyRoutingTableView()
        retainedTableViews.append(tableView)
        coordinator.tableView = tableView
        return coordinator
    }

    private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    private var backspaceCharacter: String { String(KeyScalar.backspace) }
    private var forwardDeleteCharacter: String { String(KeyScalar.forwardDelete) }

    // MARK: - 회귀: Backspace 단독 = 상위 폴더 이동 (재할당 절대 금지)

    func testBackspaceAlone_stillNavigatesUp_regressionGuard() {
        var navigatedUp = false
        var deleted = false
        let coordinator = makeCoordinator(onNavigateUp: { navigatedUp = true }, onDelete: { deleted = true })

        let event = keyEvent(characters: backspaceCharacter, modifiers: [])
        let handled = coordinator.handleKeyDown(event)

        XCTAssertTrue(handled)
        XCTAssertTrue(navigatedUp, "Backspace 단독은 여전히 상위 폴더 이동이어야 함(M1 회귀)")
        XCTAssertFalse(deleted, "Backspace 단독이 휴지통 삭제를 유발하면 절대 안 됨")
    }

    func testBackspaceWithShift_stillNavigatesUp_notDelete() {
        // handleKeyDown은 modifiers == .shift도 "일반 키" 경로로 허용한다(M1 기존 동작).
        var navigatedUp = false
        var deleted = false
        let coordinator = makeCoordinator(onNavigateUp: { navigatedUp = true }, onDelete: { deleted = true })

        let event = keyEvent(characters: backspaceCharacter, modifiers: [.shift])
        _ = coordinator.handleKeyDown(event)

        XCTAssertTrue(navigatedUp)
        XCTAssertFalse(deleted)
    }

    // MARK: - 신규: Cmd+Backspace = 휴지통 이동

    func testCommandBackspace_triggersDelete_notNavigateUp() {
        var navigatedUp = false
        var deleted = false
        let coordinator = makeCoordinator(onNavigateUp: { navigatedUp = true }, onDelete: { deleted = true })

        let event = keyEvent(characters: backspaceCharacter, modifiers: [.command])
        let handled = coordinator.handleKeyDown(event)

        XCTAssertTrue(handled, "Cmd+Backspace는 브릿지가 소비해야 함(비프음 방지)")
        XCTAssertTrue(deleted, "Cmd+Backspace는 휴지통 이동을 트리거해야 함")
        XCTAssertFalse(navigatedUp, "Cmd+Backspace가 상위 이동을 유발하면 안 됨")
    }

    // MARK: - 신규: fn+Delete(forwardDelete) = 휴지통 이동

    func testForwardDelete_triggersDelete() {
        var deleted = false
        let coordinator = makeCoordinator(onDelete: { deleted = true })

        // fn 키는 NSEvent.ModifierFlags.function으로 반영된다(deviceIndependentFlagsMask에 포함).
        let event = keyEvent(characters: forwardDeleteCharacter, modifiers: [.function])
        let handled = coordinator.handleKeyDown(event)

        XCTAssertTrue(handled)
        XCTAssertTrue(deleted, "fn+Delete는 휴지통 이동을 트리거해야 함")
    }

    // MARK: - 회귀: Caps Lock이 켜져 있어도 키 매핑이 살아 있어야 한다 (M2 리뷰 major)

    /// `.capsLock`은 사용자가 "지금 누른" 수식키가 아니라 **토글 상태**다.
    /// 이걸 걸러내지 않으면 `modifiers.isEmpty` 분기가 전부 실패해
    /// fn+Delete·F2·Enter·Backspace·Home/End/PageUp/PageDown·F5·Tab이 통째로 죽는다.
    func testUserModifiers_stripsSyntheticFlagsIncludingCapsLock() {
        let event = keyEvent(
            characters: forwardDeleteCharacter,
            modifiers: [.function, .numericPad, .capsLock, .help]
        )

        XCTAssertTrue(
            KeyScalar.userModifiers(of: event).isEmpty,
            "Caps Lock/함수키 플래그가 남으면 \"수식키 없음\" 분기에 절대 도달하지 못한다"
        )
    }

    func testUserModifiers_keepsRealModifiersWhileCapsLockIsOn() {
        let event = keyEvent(characters: backspaceCharacter, modifiers: [.capsLock, .command])

        XCTAssertEqual(
            KeyScalar.userModifiers(of: event), [.command],
            "Caps Lock을 걸러내면서 실제 수식키까지 지우면 안 된다"
        )
    }

    func testForwardDelete_withCapsLockOn_stillTriggersDelete() {
        var deleted = false
        let coordinator = makeCoordinator(onDelete: { deleted = true })

        let event = keyEvent(characters: forwardDeleteCharacter, modifiers: [.function, .capsLock])
        let handled = coordinator.handleKeyDown(event)

        XCTAssertTrue(handled)
        XCTAssertTrue(deleted, "Caps Lock이 켜져 있다고 fn+Delete가 죽으면 안 됨(M2 리뷰 major)")
    }

    func testBackspaceAlone_withCapsLockOn_stillNavigatesUp() {
        var navigatedUp = false
        var deleted = false
        let coordinator = makeCoordinator(onNavigateUp: { navigatedUp = true }, onDelete: { deleted = true })

        let handled = coordinator.handleKeyDown(keyEvent(characters: backspaceCharacter, modifiers: [.capsLock]))

        XCTAssertTrue(handled)
        XCTAssertTrue(navigatedUp, "Caps Lock 상태에서도 Backspace는 상위 폴더 이동이어야 함")
        XCTAssertFalse(deleted)
    }

    func testCommandBackspace_withCapsLockOn_stillTriggersDelete() {
        var deleted = false
        let coordinator = makeCoordinator(onDelete: { deleted = true })

        let handled = coordinator.handleKeyDown(
            keyEvent(characters: backspaceCharacter, modifiers: [.capsLock, .command])
        )

        XCTAssertTrue(handled)
        XCTAssertTrue(deleted, "Caps Lock이 Cmd+Backspace를 막으면 안 됨")
    }

    func testForwardDelete_withoutModifiers_alsoTriggersDelete() {
        // 일부 키보드 배열/환경설정에서는 순수 forwardDelete 스칼라가 modifier 없이 들어올 수 있다.
        // M1은 이 키를 이미 "소비 예약"만 해두고 무동작이었으므로, M2는 이 경로에서 삭제를 트리거해야 한다.
        var deleted = false
        let coordinator = makeCoordinator(onDelete: { deleted = true })

        let event = keyEvent(characters: forwardDeleteCharacter, modifiers: [])
        let handled = coordinator.handleKeyDown(event)

        XCTAssertTrue(handled)
        XCTAssertTrue(deleted)
    }
}
