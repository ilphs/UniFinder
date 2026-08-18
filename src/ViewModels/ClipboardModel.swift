import AppKit
import Foundation
import Observation

/// 복사/잘라내기 상태 + `NSPasteboard` 연동 (m2-impl T3).
///
/// **외부 상호 운용**: 파일 URL을 표준 `.fileURL` 타입으로 기록하므로 Finder 등 다른 앱과
/// 양방향 복사/붙여넣기가 된다. 파스트보드에는 "잘라내기" 의미론이 없으므로 cut도 외부에는
/// copy로 노출하고, **내부 붙여넣기일 때만** 이동으로 처리한다.
///
/// **외부 변경 감지 (architect B6)**: `NSPasteboard`에는 변경 알림이 없다. 상시 폴링 타이머
/// 대신 `NSApplication.didBecomeActiveNotification` 시점에 `changeCount`를 비교해
/// "내가 마지막으로 쓴 내용인지"를 판정한다. 다른 앱이 클립보드를 덮어썼다면 cut 표시를 해제한다.
@Observable
@MainActor
final class ClipboardModel {

    enum Operation: String, Equatable {
        case copy
        case cut
    }

    /// 붙여넣기 시 수행할 연산. 파스트보드 소유권을 잃으면 `nil`이 아니라 `.copy`로 강등된다.
    private(set) var operation: Operation?

    /// 내부에서 복사/잘라내기한 항목. 외부 앱이 쓴 내용은 여기에 들어오지 않는다.
    private(set) var items: [URL] = []

    /// 브릿지가 cut 표시를 다시 그릴 시점을 판단하는 카운터 (architect B6).
    /// `revision`이 바뀌지 않으면 `FileListBridge`는 `reloadData`를 하지 않는다.
    private(set) var revision: Int = 0

    /// 50% 불투명으로 그려야 할 항목들 (UI설계 §4.2).
    var cutURLs: Set<URL> {
        operation == .cut ? Set(items) : []
    }

    @ObservationIgnored
    private let pasteboard: NSPasteboard

    /// 마지막으로 우리가 파스트보드에 쓴 시점의 `changeCount`.
    @ObservationIgnored
    private var ownedChangeCount: Int = -1

    /// `canPaste` 판정 캐시. 관찰 대상이 아니므로 뷰 갱신 사이클을 유발하지 않는다.
    @ObservationIgnored
    private var cachedPasteAvailability: (changeCount: Int, value: Bool)?

    @ObservationIgnored
    private var activationObserver: NSObjectProtocol?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    // MARK: - 기록

    func copy(_ urls: [URL]) {
        write(urls, operation: .copy)
    }

    func cut(_ urls: [URL]) {
        write(urls, operation: .cut)
    }

    private func write(_ urls: [URL], operation newOperation: Operation) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        ownedChangeCount = pasteboard.changeCount
        items = urls
        operation = newOperation
        revision &+= 1
    }

    /// cut 소비 후 클립보드를 비운다 (m2-impl T4).
    func clear() {
        items = []
        operation = nil
        revision &+= 1
    }

    // MARK: - 읽기

    /// 파스트보드가 아직 우리 것인지 (= 내부 cut 의미론을 적용해도 되는지).
    var ownsPasteboard: Bool {
        pasteboard.changeCount == ownedChangeCount
    }

    /// 붙여넣기 가능 여부 — 외부 앱이 넣어둔 파일 URL도 포함한다.
    ///
    /// 메뉴 활성 조건이라 SwiftUI 뷰 갱신마다 평가된다. `readObjects`는 IPC라 매번 호출하면
    /// 비싸므로 `changeCount`가 그대로면 직전 판정을 재사용한다(값이 바뀌는 유일한 계기가
    /// `changeCount` 변화이므로 안전하다).
    var canPaste: Bool {
        let currentCount = pasteboard.changeCount
        if let cached = cachedPasteAvailability, cached.changeCount == currentCount {
            return cached.value
        }
        let value = !pasteboardURLs().isEmpty
        cachedPasteAvailability = (currentCount, value)
        return value
    }

    /// 붙여넣기 대상과 수행할 연산.
    ///
    /// 파스트보드 소유권을 잃었다면(다른 앱이 덮어씀) 내용은 외부 것이므로 항상 **복사**다.
    func pasteSource() -> (items: [URL], operation: Operation) {
        let urls = pasteboardURLs()
        guard ownsPasteboard, operation == .cut else {
            return (urls, .copy)
        }
        return (urls, .cut)
    }

    /// "무조건 이동"으로 붙여넣을 대상 (Finder의 Move Items Here — ⌥⌘V, 2026-08-18 D단계).
    ///
    /// `pasteSource()`는 파스트보드 소유권을 잃으면 연산을 `.copy`로 **강등**한다. 그건
    /// "외부 앱이 넣어둔 내용에 우리 쪽 cut 의미론을 **추론으로** 적용하지 않는다"는 안전 기본값이다.
    /// 이 진입점은 그 기본값을 **의도적으로 뚫는다** — ⌥⌘V는 사용자가 "이동"을 직접 명시한
    /// 명령이지 추론이 아니고, Finder도 외부 클립보드에 대해 똑같이 이동한다.
    /// 그래서 강등 규칙은 `pasteSource()`에만 남기고 여기서는 **항목만** 돌려준다.
    func moveSourceItems() -> [URL] {
        pasteboardURLs()
    }

    private func pasteboardURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else { return [] }
        return objects
    }

    // MARK: - 외부 변경 감지 (architect B6)

    /// 앱 재활성화 시점마다 파스트보드 소유권을 재확인한다 (상시 폴링 금지).
    func startObservingPasteboard() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.syncWithPasteboard()
            }
        }
    }

    func stopObservingPasteboard() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    /// 파스트보드가 외부에서 바뀌었으면 cut 상태(와 그 시각 표시)를 해제한다.
    /// - Returns: 상태가 실제로 바뀌었으면 `true`
    @discardableResult
    func syncWithPasteboard() -> Bool {
        guard !ownsPasteboard else { return false }
        guard operation != nil || !items.isEmpty else { return false }
        items = []
        operation = nil
        revision &+= 1
        return true
    }
}
