import AppKit

/// `NSEvent.charactersIgnoringModifiers` 비교용 스칼라 상수 모음.
///
/// AppKit의 키 상수(`NSUpArrowFunctionKey` 등)는 `Int`라 매번 변환이 필요해서
/// 브릿지 Coordinator(T3/T4)가 공유하는 한 곳에 모아둔다.
enum KeyScalar {
    static let tab = UnicodeScalar(UInt32(NSTabCharacter))!
    static let carriageReturn = UnicodeScalar(UInt32(NSCarriageReturnCharacter))!
    static let enter = UnicodeScalar(UInt32(NSEnterCharacter))!
    static let newline = UnicodeScalar(UInt32(NSNewlineCharacter))!
    static let backspace = UnicodeScalar(UInt32(NSDeleteCharacter))!
    static let escape = UnicodeScalar(UInt32(27))!
    static let space = UnicodeScalar(UInt32(32))!

    static let upArrow = UnicodeScalar(UInt32(NSUpArrowFunctionKey))!
    static let downArrow = UnicodeScalar(UInt32(NSDownArrowFunctionKey))!
    static let home = UnicodeScalar(UInt32(NSHomeFunctionKey))!
    static let end = UnicodeScalar(UInt32(NSEndFunctionKey))!
    static let pageUp = UnicodeScalar(UInt32(NSPageUpFunctionKey))!
    static let pageDown = UnicodeScalar(UInt32(NSPageDownFunctionKey))!
    static let forwardDelete = UnicodeScalar(UInt32(NSDeleteFunctionKey))!
    static let f2 = UnicodeScalar(UInt32(NSF2FunctionKey))!
    static let f5 = UnicodeScalar(UInt32(NSF5FunctionKey))!

    /// SwiftUI `KeyEquivalent`용 F5 문자.
    static let f5Character = Character(f5)

    /// 기능키(0xF700~) 영역 여부 — 타입-어헤드 대상에서 제외한다.
    static func isFunctionKey(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }

    /// AppKit이 **자동으로** 붙이거나 사용자가 누르지 않아도 켜져 있는 플래그 —
    /// "사용자가 지금 누른 수식키"가 아니다.
    ///
    /// - `.function`: `Home`/`End`/`PageUp`/`PageDown`/`F2`/`fn+Delete`/방향키에 항상 붙는다
    /// - `.numericPad`: 방향키·숫자패드 키에 항상 붙는다
    /// - `.capsLock`(1<<16): **토글 상태**다. Caps Lock이 켜져 있는 동안 모든 `keyDown`에 붙으므로
    ///   걸러내지 않으면 `modifiers.isEmpty` 분기가 전부 실패해 fn+Delete·F2·Enter·Backspace·
    ///   Home/End/PageUp/PageDown·F5·Tab이 통째로 무동작이 된다 (M2 리뷰 major)
    /// - `.help`: 일부 키보드가 `fn`/`help` 키에 함께 올리는 플래그
    ///
    /// 이걸 걸러내지 않으면 "수식키 없음" 분기 조건(`modifiers.isEmpty`)에 절대 걸리지 않아
    /// 해당 키들이 브릿지에 도달하지 못한다 (m2-impl T2 — `fn+Delete` 휴지통 이동의 전제 조건).
    static let syntheticModifiers: NSEvent.ModifierFlags = [.function, .numericPad, .capsLock, .help]

    /// 사용자가 실제로 누른 수식키만 남긴 플래그.
    static func userModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        userModifiers(event.modifierFlags)
    }

    /// 이벤트가 없는 자리(드래그 세션의 수식키 판정 — m3-impl T3/B13)에서 쓰는 같은 규칙.
    static func userModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(syntheticModifiers)
    }
}
