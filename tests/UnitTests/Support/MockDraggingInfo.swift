import AppKit

/// 브릿지의 드롭 콜백을 **실제 시그니처 그대로** 호출하기 위한 `NSDraggingInfo` 테스트 대역.
///
/// M3 리뷰가 지적한 사각지대를 메우기 위해 만들었다: `DragDropPolicy`의 순수 판정만 테스트되고,
/// "브릿지가 그 판정을 **언제 어떤 입력으로** 부르는지"는 커버되지 않아
/// `acceptDrop`이 `NSEvent.modifierFlags`를 다시 읽는 결함이 테스트를 통과했다.
///
/// 여기서 중요한 것은 `draggingSourceOperationMask`(드래그 세션이 들고 있는 허용 오퍼레이션)와
/// `draggingPasteboard` 둘뿐이다. 나머지 요구 멤버는 프로토콜 충족을 위한 최소 구현이다.
/// - Note: `NSDraggingInfo`의 요구 멤버는 SDK에서 UI 액터로 표기돼 있지 않은 것이 섞여 있어
///   클래스 전체를 `@MainActor`로 두면 적합성 선언이 액터 경계를 넘는다(Swift 6에서 에러).
///   이 대역은 상태를 테스트와 같은 컨텍스트에서만 만지므로 격리 없이 둔다.
final class MockDraggingInfo: NSObject, NSDraggingInfo {

    /// 소스가 허용한 오퍼레이션. AppKit은 사용자가 누른 수식키를 이 값에 이미 반영해서 준다
    /// (Option → `.copy`, Command → `.move`). 테스트는 그 상태를 직접 만들어 넣는다.
    var draggingSourceOperationMask: NSDragOperation

    let draggingPasteboard: NSPasteboard

    init(urls: [URL], sourceMask: NSDragOperation, pasteboardName: String = UUID().uuidString) {
        self.draggingSourceOperationMask = sourceMask
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MockDraggingInfo-\(pasteboardName)"))
        pasteboard.clearContents()
        if !urls.isEmpty {
            pasteboard.writeObjects(urls.map { $0 as NSURL })
        }
        self.draggingPasteboard = pasteboard
        super.init()
    }

    // MARK: - 나머지 요구 멤버 (동작에 관여하지 않는다)

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    // deprecated 요구 멤버 — 프로토콜 충족을 위해서만 존재한다(호출되지 않는다).
    var draggedImage: NSImage? { nil }

    // `NSObject`의 옛 비공식 프로토콜 카테고리와 이름이 겹쳐 `override`가 필요하다.
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
