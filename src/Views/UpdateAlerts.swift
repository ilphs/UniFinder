import SwiftUI

/// 업데이트 확인 결과 알림 3종 (후속 T3 / UI설계 §7.9).
///
/// **왜 알림(alert)인가**: 결과는 (a) 사용자가 명시적으로 요청한 조작의 응답이거나
/// (b) 행동을 요구하는 정보다. UI설계 §8의 "탐색을 막는 모달 금지" 원칙은 **탐색 중 발생하는
/// 사건**(폴더 접근 실패 등)에 대한 규칙이고, 이 둘은 그 범주가 아니다.
///
/// **창 하나만 띄운다**: `UpdateCheckModel`은 앱 전역 인스턴스인데 `.alert`는 창마다 붙는
/// 모디파이어라, 게이팅이 없으면 열린 창 전부가 같은 알림을 동시에 띄운다
/// (FDA 온보딩 시트와 완전히 같은 문제 — `AppEnvironment.globalAlertPresenterID`).
///
/// **구식 `Alert` 값 타입을 쓰지 않는 이유**: 새 버전 알림은 버튼이 셋
/// (Skip This Version · Later · Download)인데 `Alert(primaryButton:secondaryButton:)`은 둘까지다.
struct UpdateCheckAlertModifier: ViewModifier {

    @Bindable var model: UpdateCheckModel

    /// 이 창이 알림 소유 창인지.
    let isPresenter: Bool

    private var presentation: UpdateCheckModel.Presentation? {
        isPresenter ? model.presentation : nil
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { presentation != nil },
            // 알림이 닫히는 모든 경로(버튼·Esc)가 이 지점을 지난다.
            set: { if !$0 { model.dismiss() } }
        )
    }

    func body(content: Content) -> some View {
        content.alert(
            Self.title(for: presentation),
            isPresented: isPresented,
            presenting: presentation
        ) { presentation in
            switch presentation {
            case let .available(release, _):
                // 순서: 파괴적이지 않은 것 → 기본 행동. `Download`가 기본 버튼이다.
                Button("Skip This Version") { model.skip(release) }
                Button("Later", role: .cancel) { model.dismiss() }
                Button("Download") { _ = model.download(release) }

            case .upToDate, .failed:
                Button("OK", role: .cancel) { model.dismiss() }
            }
        } message: { presentation in
            Text(Self.message(for: presentation))
        }
    }

    // MARK: - 문구 (UI 문자열이므로 영어)

    static func title(for presentation: UpdateCheckModel.Presentation?) -> String {
        switch presentation {
        case let .available(release, _):
            return "UniFinder \(release.version.description) is available."
        case .upToDate:
            return "You're up to date."
        case .failed:
            return "Couldn't check for updates."
        case nil:
            return ""
        }
    }

    static func message(for presentation: UpdateCheckModel.Presentation) -> String {
        switch presentation {
        case let .available(release, current):
            return availableMessage(release: release, current: current)
        case let .upToDate(current):
            return "UniFinder \(current.description) is the latest version."
        case let .failed(message):
            return message
        }
    }

    /// 새 버전 알림 본문 — 현재 버전 + 릴리스 노트 **원문**.
    ///
    /// 마크다운을 렌더링하지 않는다(UI설계 §7.9): 릴리스 노트는 우리가 통제하지 않는 외부
    /// 문자열이고, 스타일 해석을 시작하면 깨진 마크업이 곧 깨진 화면이 된다. 원문 그대로가 정직하다.
    /// 너무 길면 알림이 화면을 넘기므로 **앞부분만** 싣고 나머지는 릴리스 페이지에 맡긴다.
    static func availableMessage(release: UpdateRelease, current: SemanticVersion) -> String {
        var lines = ["You have \(current.description)."]
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("")
            lines.append("What's New")
            lines.append(truncatedNotes(notes))
        }
        return lines.joined(separator: "\n")
    }

    /// 알림 본문에 실을 최대 길이. 넘으면 잘라내고 말줄임을 붙인다.
    static let maximumNotesLength = 800

    static func truncatedNotes(_ notes: String) -> String {
        guard notes.count > maximumNotesLength else { return notes }
        return String(notes.prefix(maximumNotesLength)) + "…"
    }
}

extension View {

    /// - Parameter isPresenter: 이 창이 알림 소유 창인지 (`AppModel.isGlobalAlertPresenter`).
    func updateCheckAlert(_ model: UpdateCheckModel, isPresenter: Bool) -> some View {
        modifier(UpdateCheckAlertModifier(model: model, isPresenter: isPresenter))
    }
}
