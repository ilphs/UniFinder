import SwiftUI

/// 툴바 (UI설계 §2): `[⬅][➡][⬆]  [breadcrumb 주소창]  [⟳]`
struct ToolbarBar: View {

    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                toolbarButton(system: "chevron.left", help: "뒤로 (⌘[)", enabled: model.navigation.canGoBack) {
                    model.goBack()
                }
                toolbarButton(system: "chevron.right", help: "앞으로 (⌘])", enabled: model.navigation.canGoForward) {
                    model.goForward()
                }
                toolbarButton(system: "chevron.up", help: "상위 폴더 (⌘↑)", enabled: model.navigation.canGoUp) {
                    model.goUp()
                }
            }

            BreadcrumbBar(
                url: model.navigation.currentURL,
                isEditing: $model.isAddressEditing,
                shakeTrigger: model.addressShakeTrigger,
                onNavigate: { model.navigate(to: $0, source: .breadcrumb) },
                onSubmit: { model.submitAddress($0) }
            )
            .frame(maxWidth: .infinity)

            toolbarButton(system: "arrow.clockwise", help: "새로 고침 (⌘R)", enabled: true) {
                model.refresh()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func toolbarButton(
        system: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}
