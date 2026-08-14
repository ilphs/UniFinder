import AppKit
import Foundation

/// 드래그앤드롭의 **판정 규칙**만 모아둔 곳 (m3-impl T3/B13).
///
/// 목록 브릿지와 트리 브릿지가 같은 규칙을 써야 "목록→트리"와 "트리→트리"가 다르게 동작하지 않는다.
/// 실행은 하지 않는다 — 드롭 실행의 단일 진입점은 `AppModel.drop(_:into:operation:)`이다(B9).
enum DragDropPolicy {

    /// 드래그 중 사용자가 실제로 누르고 있는 수식키.
    ///
    /// M2에서 확립한 합성 플래그 제거 규칙(`KeyScalar.userModifiers`)을 그대로 쓴다 —
    /// Caps Lock이 켜져 있으면 모든 판정이 어긋나던 그 문제와 같은 뿌리다.
    static func userModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        KeyScalar.userModifiers(flags)
    }

    /// 기본 동작: **같은 볼륨 = 이동, 다른 볼륨 = 복사** (Win10·Finder 공통 관례).
    /// 수식키: `Option` = 복사 강제, `Command` = 이동 강제.
    ///
    /// 둘 다 눌렸으면 복사(비파괴)를 택한다 — 오조작의 되돌림 수단이 휴지통 복원뿐이므로(B13),
    /// 모호한 입력에서는 파괴적이지 않은 쪽으로 기운다.
    ///
    /// - Important: 브릿지는 이 오버로드를 쓰지 않는다. 드래그 중의 수식키 상태는
    ///   `NSEvent.modifierFlags`(전역 *현재* 상태)가 아니라 드래그 세션이 들고 있는
    ///   `NSDraggingInfo.draggingSourceOperationMask`로 읽어야 한다 —
    ///   아래 `operation(sourceMask:isSameVolume:)` 참조(M3 리뷰 blocker 1).
    ///
    /// - Warning: **프로덕션에서 쓰이지 않는다**(호출자는 이 규칙을 기록해 둔 테스트뿐). blocker 1이
    ///   금지한 바로 그 입력(`NSEvent.modifierFlags`)을 받는 API가 아무 표시 없이 남아 있으면
    ///   다음 사람이 다시 집어 든다 — 그래서 사용하면 컴파일러가 경고하도록 표시해 둔다(리뷰 선택 5).
    @available(*, deprecated, message: "드래그 판정은 NSEvent.modifierFlags가 아니라 draggingSourceOperationMask로 한다 — operation(sourceMask:isSameVolume:)를 쓸 것(M3 리뷰 blocker 1)")
    static func operation(modifiers: NSEvent.ModifierFlags, isSameVolume: Bool) -> FileOperationKind {
        let userFlags = userModifiers(modifiers)
        if userFlags.contains(.option) { return .copy }
        if userFlags.contains(.command) { return .move }
        return isSameVolume ? .move : .copy
    }

    /// 드래그 소스가 허용한 오퍼레이션 마스크와 **교집합**을 취한 최종 판정 (M3 리뷰 blocker 1).
    ///
    /// **왜 `NSEvent.modifierFlags`를 다시 읽으면 안 되는가**
    /// - (a) 배지와 실제 동작이 어긋난다: `validateDrop`에서 Option을 눌러 "복사" 배지를 본 사용자가
    ///   마우스 버튼보다 Option을 먼저 떼면, `acceptDrop`이 다시 읽은 전역 플래그에는 Option이 없어
    ///   같은 볼륨 기본값인 **이동**이 나온다. 사용자는 복사를 봤는데 원본이 사라진다 —
    ///   되돌림 수단이 휴지통 복원뿐인 이 앱에서 가장 피해야 할 방향의 오판이다(B13).
    /// - (b) 외부 앱의 제약을 무시한다: 소스가 `.copy`만 허용한 드래그도 같은 볼륨이면 이동으로
    ///   처리해, 파일을 소유한 앱 아래에서 원본을 옮긴다(볼륨 간이면 EXDEV 폴백이 원본을 휴지통으로 보낸다).
    ///
    /// AppKit은 사용자가 누르고 있는 수식키를 **이미 이 마스크에 반영**해서 준다(Option → `.copy`,
    /// Command → `.move`). 그래서 마스크 하나만 보면 (a)와 (b)가 동시에 닫힌다.
    ///
    /// - Returns: 이동/복사 어느 쪽도 허용되지 않으면 `nil`(= 드롭을 받지 않는다)
    static func operation(sourceMask: NSDragOperation, isSameVolume: Bool) -> FileOperationKind? {
        let allowsMove = sourceMask.contains(.move)
        let allowsCopy = sourceMask.contains(.copy)
        switch (allowsMove, allowsCopy) {
        case (true, true):
            // 수식키가 없거나(원본 마스크 그대로) 둘 다 눌린 경우 — 볼륨 기준 기본값으로 간다.
            return isSameVolume ? .move : .copy
        case (true, false):
            return .move
        case (false, true):
            return .copy
        case (false, false):
            // 명시 비트가 하나도 없을 때만 `.generic`("동작은 대상이 정한다")을 인정한다.
            // `.link`/`.private`/`.delete`뿐인 마스크는 파일 이동·복사의 근거가 되지 않으므로 거부한다.
            //
            // **`.generic` 단독은 볼륨과 무관하게 복사다**(M3 리뷰 권장 2). Cocoa 의미론상 대상이
            // 정해도 되는 자리지만, 여기서 같은 볼륨 기본값(이동)으로 가면 **소스가 이동을 한 번도
            // 명시하지 않았는데 원본을 지우는** 셈이 된다. 위 21행이 세운 원칙 — 모호한 입력에서는
            // 비파괴 쪽으로 기운다 — 이 그대로 적용되는 자리다.
            return sourceMask.contains(.generic) ? .copy : nil
        }
    }

    /// 현재 마스크가 **이 판정을 여전히 허용하는가** (아래 `settle`의 판단 근거).
    ///
    /// `operation(sourceMask:isSameVolume:)`이 마스크를 **하나의 결론으로 접는** 함수라면, 이쪽은
    /// 접기 전의 허용 집합을 그대로 묻는다. 둘을 구분해야 하는 이유는 `[.copy, .move]`처럼
    /// 둘 다 허용하는 마스크가 결론으로는 하나(볼륨 기본값)만 내놓기 때문이다 —
    /// 결론끼리 비교하면 "복사도 여전히 허용된다"는 사실이 사라진다.
    static func permits(_ kind: FileOperationKind, sourceMask: NSDragOperation) -> Bool {
        let allowsMove = sourceMask.contains(.move)
        let allowsCopy = sourceMask.contains(.copy)
        guard allowsMove || allowsCopy else {
            // 명시 비트가 없는 마스크 — `.generic` 단독이면 복사만 근거가 된다(위 규칙과 동일).
            return sourceMask.contains(.generic) && kind == .copy
        }
        return kind == .move ? allowsMove : allowsCopy
    }

    /// `validateDrop`이 배지로 확인시킨 판정(`recalled`)과 **드롭이 확정된 순간의 마스크**를 합쳐
    /// 최종 판정을 낸다 (M3 리뷰 권장 1).
    ///
    /// 캐시(`DropDecision`)는 (a) "배지와 다른 동작"을 막으려고 도입했지만, 캐시를 **무조건**
    /// 우선하면 (b)("소스가 허용하지 않은 이동")가 좁게 다시 열린다: 마지막 `validateDrop` 이후
    /// Option이 눌린 채 드롭이 확정되고 AppKit이 재검증을 보내지 않으면, 캐시에 남은 `.move`가
    /// 마스크의 copy-only 제한을 덮어쓴다 — 방향이 파괴적이다(원본 소실).
    ///
    /// 그래서 규칙은 **"현재 마스크가 그 판정을 여전히 허용할 때만 캐시를 쓴다"**이다.
    /// - (a) 마스크가 둘 다 허용 → 배지로 보여준 판정을 그대로 유지한다(수식키를 버튼보다 먼저 뗀 경우)
    /// - (b) 마스크가 한쪽으로 제한 → 마스크가 이긴다(소스의 제약은 사용자 배지보다 강하다)
    ///
    /// 마스크가 이동·복사 어느 쪽도 허용하지 않으면 `nil`(= 받지 않는다) — `validateDrop`이
    /// 같은 입력에서 내리는 결론과 같게 둔다. 캐시된 판정을 근거 없는 마스크 위에서 실행하지 않는다.
    static func settle(
        recalled: FileOperationKind?,
        sourceMask: NSDragOperation,
        isSameVolume: Bool
    ) -> FileOperationKind? {
        let masked = operation(sourceMask: sourceMask, isSameVolume: isSameVolume)
        guard let recalled, masked != nil else { return masked }
        return permits(recalled, sourceMask: sourceMask) ? recalled : masked
    }

    /// 드롭 대상 폴더 기준으로 소스 전체가 같은 볼륨에 있는지.
    /// 하나라도 다른 볼륨이면 전체를 다른 볼륨으로 취급한다(혼합 드롭에서 일부만 이동하지 않도록).
    static func isSameVolume(urls: [URL], destination: URL) -> Bool {
        urls.allSatisfy { isSameVolume($0, destination) }
    }

    /// `validateDrop`에서 확정한 판정을 `acceptDrop`까지 나르는 1칸 캐시 (M3 리뷰 blocker 1).
    ///
    /// 두 콜백이 각자 판정하면 그사이에 바뀐 입력이 그대로 결과를 뒤집는다.
    /// **사용자가 커서 배지로 확인하고 놓은 판정**을 그대로 실행하는 것이 이 캐시의 존재 이유다.
    /// 대상 폴더가 달라졌으면(마지막 validate 이후 다른 행 위로 옮겨간 경우) 캐시를 쓰지 않는다.
    struct DropDecision: Equatable {

        private var destinationKey: String?
        private var kind: FileOperationKind?

        init() {}

        /// `validateDrop`이 확정한 판정을 기록한다(= 사용자에게 배지로 보여준 것).
        mutating func record(_ kind: FileOperationKind, destination: URL) {
            self.destinationKey = PathKey.key(destination)
            self.kind = kind
        }

        /// 같은 대상에 대해 기록된 판정을 되찾는다. 없으면 `nil`(호출부가 마스크로 새로 판정한다).
        func recall(destination: URL) -> FileOperationKind? {
            guard let destinationKey, destinationKey == PathKey.key(destination) else { return nil }
            return kind
        }

        mutating func clear() {
            destinationKey = nil
            kind = nil
        }
    }

    /// 두 경로가 같은 볼륨에 있는지 — **경로 접두사가 아니라 `volumeIdentifier` 비교**다(B13).
    ///
    /// macOS의 firmlink(`/Users/x` ↔ `/System/Volumes/Data/Users/x`)와 마운트 포인트 때문에
    /// 문자열 접두사 비교는 같은 볼륨을 다른 볼륨으로, 또는 그 반대로 오판한다.
    /// 판정할 수 없으면 `false`(= 복사)로 기울인다 — 이동은 원본을 없애므로 확신이 없으면 하지 않는다.
    static func isSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = volumeIdentifier(of: lhs), let right = volumeIdentifier(of: rhs) else { return false }
        return left.isEqual(right)
    }

    private static func volumeIdentifier(of url: URL) -> (NSCopying & NSSecureCoding & NSObjectProtocol)? {
        // 아직 만들어지지 않은 대상(드롭 결과 경로)일 수 있으므로 존재하는 조상까지 올라가며 묻는다.
        var candidate: URL? = url
        for _ in 0..<128 {
            guard let current = candidate else { return nil }
            if let values = try? current.resourceValues(forKeys: [.volumeIdentifierKey]),
               let identifier = values.volumeIdentifier {
                return identifier
            }
            candidate = PathKey.parent(of: current)
        }
        return nil
    }

    /// 드롭 대상 폴더가 원본 자신이거나 원본의 하위인지 — **UI 레벨 사전 거부용**(커서 금지 배지).
    ///
    /// 최종 권위는 `FileOperations`의 가드다(B10). 여기서 통과해도 서비스가 거부하며, 여기서
    /// 거부하는 이유는 사용자에게 드롭 전에 피드백을 주기 위해서다. 그래서 판정 기법도
    /// 서비스와 동일하게 **문자열 + 심볼릭 링크 해석 2축**을 쓴다(별칭 노드 드롭 — 선처리 B1).
    static func isDropTargetInsideSource(_ destination: URL, source: URL) -> Bool {
        if PathKey.isSameOrDescendant(destination, of: source) { return true }
        let resolvedDestination = destination.resolvingSymlinksInPath()
        let resolvedSource = source.resolvingSymlinksInPath()
        return PathKey.isSameOrDescendant(resolvedDestination, of: resolvedSource)
    }

    /// 드롭을 받아도 되는지 (UI 레벨 보조 판정).
    ///
    /// - 대상이 원본 자신/하위면 거부
    /// - 원본의 부모 = 대상이면 **거부하지 않는다**: 같은 폴더 드롭은 이동이면 no-op, 복사면
    ///   자동 넘버링이라는 정의된 동작이 있다(UI설계 §7.1 / 선처리 B2). 여기서 막으면
    ///   "복사 수식키를 눌러 같은 폴더에 사본 만들기"가 불가능해진다.
    static func canAcceptDrop(urls: [URL], into destination: URL) -> Bool {
        guard !urls.isEmpty else { return false }
        return !urls.contains { isDropTargetInsideSource(destination, source: $0) }
    }

    /// 파스트보드에서 파일 URL만 추출한다 (Finder·타 앱과의 상호 운용 경로).
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else { return [] }
        return objects.filter(\.isFileURL)
    }

    /// 드롭 동작 종류 → AppKit 드래그 오퍼레이션(커서 배지).
    static func draggingOperation(for kind: FileOperationKind) -> NSDragOperation {
        kind == .move ? .move : .copy
    }
}
