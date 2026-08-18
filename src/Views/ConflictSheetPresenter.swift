import AppKit
import Foundation

/// 이름 충돌 시트 (UI설계 §7.1). `FileOperations`(actor)가 `ConflictResolving`으로만 알고 있는
/// 프레젠터 구현체 — Services는 이 타입을 모른다 (설계서 §3.1 의존 방향 유지).
///
/// **취소 안전성 (m2-impl T0 수용 기준)**: 작업 Task가 취소되면 시트를 닫고 대기 중인
/// continuation을 반드시 `.cancel`로 재개시킨다. 재개를 빠뜨리면 조작 Task가 영구히 행이 되고
/// `AppModel`의 작업 슬롯이 잠긴다. `onCancel`이 시트 표시보다 먼저 도착하는 경쟁도
/// `cancelledIDs`로 흡수한다.
@MainActor
final class ConflictSheetPresenter: ConflictResolving {

    /// 시트를 붙일 윈도우 공급자. `nil`이거나 보이지 않으면(헤드리스/테스트) 취소로 응답한다.
    var windowProvider: () -> NSWindow? = { NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow }

    private struct PendingSheet {
        let continuation: CheckedContinuation<ConflictDecision, Never>
        let alert: NSAlert
    }

    private var pending: [Int: PendingSheet] = [:]
    /// 아직 결과가 정해지지 않은(ID 예약 ~ 종료 전) 요청들.
    ///
    /// 이 집합이 있어야 **이미 끝난 요청에 뒤늦게 도착한 취소**를 걸러낼 수 있다 (M2 백로그 B4):
    /// `onCancel`은 `Task { @MainActor }` 한 홉을 거치므로 continuation이 이미 재개된 뒤에 도착할 수
    /// 있고, 그때 `cancelledIDs`에 넣으면 아무도 소비하지 않아 조작 1건당 영구히 쌓인다.
    private var liveIDs: Set<Int> = []
    /// 시트가 뜨기 전에 취소가 먼저 도착한 요청들. 항상 `present`가 소비한다.
    private var cancelledIDs: Set<Int> = []
    private var nextID = 0

    init() {}

    // MARK: - ConflictResolving

    nonisolated func resolve(_ conflict: FileConflict) async -> ConflictDecision {
        let id = await reserveID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConflictDecision, Never>) in
                Task { @MainActor in
                    self.present(conflict, id: id, continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel(id: id)
            }
        }
    }

    // MARK: - 시트

    private func reserveID() -> Int {
        nextID &+= 1
        liveIDs.insert(nextID)
        return nextID
    }

    /// 어떤 경로로 끝났든 요청 ID의 흔적을 지운다 — 상태가 누적되지 않는 유일한 지점(B4).
    private func settle(id: Int) {
        liveIDs.remove(id)
        cancelledIDs.remove(id)
    }

    private func present(
        _ conflict: FileConflict,
        id: Int,
        continuation: CheckedContinuation<ConflictDecision, Never>
    ) {
        // 시트가 뜨기 전에 취소가 먼저 도착한 경우
        if cancelledIDs.contains(id) {
            settle(id: id)
            continuation.resume(returning: .cancel)
            return
        }
        guard let window = windowProvider(), window.isVisible else {
            settle(id: id)
            continuation.resume(returning: .cancel)
            return
        }

        let alert = Self.makeAlert(for: conflict)
        pending[id] = PendingSheet(continuation: continuation, alert: alert)

        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.finish(id: id, response: response)
            }
        }
    }

    private func finish(id: Int, response: NSApplication.ModalResponse) {
        guard let sheet = pending.removeValue(forKey: id) else { return }
        settle(id: id)
        let applyToAll = (sheet.alert.accessoryView as? NSButton)?.state == .on
        let resolution = Self.resolution(for: response)
        sheet.continuation.resume(
            returning: ConflictDecision(
                resolution: resolution,
                // "취소"에 모두 적용은 의미가 없다(어차피 전체 중단).
                applyToAll: applyToAll && resolution != .cancel
            )
        )
    }

    /// 취소 전달. `resolve`의 `onCancel`에서만 호출한다(테스트는 "뒤늦은 취소" 재현에 직접 쓴다).
    func cancel(id: Int) {
        guard let sheet = pending.removeValue(forKey: id) else {
            // 아직 시트가 뜨지 않은 요청만 표식을 남긴다. 이미 결과가 정해진 요청(`liveIDs`에 없음)에
            // 뒤늦게 도착한 취소는 소비할 주체가 없으므로 버린다 — 남기면 그대로 누수다(B4).
            if liveIDs.contains(id) {
                cancelledIDs.insert(id)
            }
            return
        }
        settle(id: id)
        if let sheetWindow = sheet.alert.window.sheetParent {
            sheetWindow.endSheet(sheet.alert.window, returnCode: .cancel)
        }
        sheet.continuation.resume(returning: .cancel)
    }

    // MARK: - 상태 관측 (누수 회귀 고정용)

    /// 아직 소비되지 않은 "선취소" 표식 수. 조작이 끝난 뒤에도 남아있으면 누수다(B4).
    var pendingCancellationMarkerCount: Int { cancelledIDs.count }

    /// 진행 중(결과 미정) 요청 수. 조작이 끝난 뒤에는 0이어야 한다.
    var liveRequestCount: Int { liveIDs.count }

    // MARK: - 알림 구성 (UI설계 §7.1)

    /// 버튼은 추가 순서의 **역순**으로(우→좌) 배치된다.
    /// UI설계 §7.1의 `[Keep Both] [Skip] [Cancel] [Replace(기본)]` 배열을 그대로 얻기 위해
    /// Replace → Cancel → Skip → Keep Both 순으로 추가한다.
    static func makeAlert(for conflict: FileConflict) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An item named \"\(conflict.name)\" already exists."
        alert.informativeText = informativeText(for: conflict)

        alert.addButton(withTitle: "Replace")        // 기본 = Enter
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"      // Esc = 전체 작업 중단
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Keep Both")

        if conflict.remainingCount > 0 {
            let remaining = conflict.remainingCount
            let title = remaining == 1 ? "Apply to the remaining item" : "Apply to the remaining \(remaining) items"
            let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            checkbox.sizeToFit()
            alert.accessoryView = checkbox
        }
        return alert
    }

    static func informativeText(for conflict: FileConflict) -> String {
        let source = "Source:  \(Formatters.displaySize(conflict.sourceSize)) · \(Formatters.displayDate(conflict.sourceModifiedAt))"
        let destination = "Destination:  \(Formatters.displaySize(conflict.destinationSize)) · \(Formatters.displayDate(conflict.destinationModifiedAt))"
        return "\(source)\n\(destination)"
    }

    /// 4번째 버튼("Keep Both"). `NSApplication.ModalResponse`에는 3번째까지만 상수가 있다
    /// (AppKit 규약: 네 번째부터는 `alertThirdButtonReturn + n`).
    static let alertFourthButtonReturn = NSApplication.ModalResponse(
        rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1
    )

    /// 버튼 응답 → 충돌 결정.
    ///
    /// **알 수 없는 응답은 `.cancel`이다** (M2 백로그 B3): 예전에는 `default`가 `.keepBoth`였는데,
    /// 그건 "파일을 하나 더 만든다"는 부작용이 있는 선택이다. 시트가 예상 밖 경로로 닫히면
    /// (`.abort`/`.stop`/M3에서 늘어날 취소 UI) 사용자가 고르지도 않은 사본이 생긴다.
    /// 안전한 기본값은 아무것도 하지 않는 `.cancel`이다.
    static func resolution(for response: NSApplication.ModalResponse) -> ConflictResolution {
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .cancel
        case .alertThirdButtonReturn: return .skip
        case Self.alertFourthButtonReturn: return .keepBoth
        default: return .cancel
        }
    }
}
