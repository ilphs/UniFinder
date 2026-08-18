import SwiftUI

/// FDA 웰컴 시트 (UI설계 §7.5 / m3-impl T5).
///
/// 안내 → [시스템 설정 열기] 딥링크 → [나중에]. 앱으로 돌아오면
/// `FullDiskAccessModel`이 `didBecomeActive`에서 재감지해 허용 시 이 시트를 자동으로 닫는다.
struct OnboardingSheet: View {

    @Bindable var model: FullDiskAccessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.open.display")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("UniFinder needs Full Disk Access to browse all of your files")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Most of your home folder works without it, but some system and app data folders can't be opened.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                stepText("1. Click [Open System Settings].")
                stepText("2. Turn on UniFinder in the list.")
                stepText("3. Return to UniFinder — the change is detected automatically.")
            }
            .padding(.leading, 40)

            if model.deepLinkFailed {
                Text("System Settings couldn't be opened. Allow UniFinder in System Settings > Privacy & Security > Full Disk Access.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Later") { model.postpone() }
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings") { model.openSystemSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func stepText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 제한 모드 안내 배너 (설계 §8 — 미허용으로 단정하지 않고 온화하게).
struct FullDiskAccessBanner: View {

    let model: FullDiskAccessModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(model.bannerMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button("How to Grant Access") { model.present() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

extension View {

    /// FDA 온보딩 시트 + 제한 모드 배너를 한 번에 붙인다.
    ///
    /// 기존 뷰 계층 수정을 1줄로 제한하기 위한 진입점이다(다른 태스크와의 파일 충돌 회피).
    func fullDiskAccessOnboarding(_ model: FullDiskAccessModel) -> some View {
        modifier(FullDiskAccessOnboardingModifier(model: model))
    }
}

private struct FullDiskAccessOnboardingModifier: ViewModifier {

    @Bindable var model: FullDiskAccessModel

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.shouldShowBanner {
                    VStack(spacing: 0) {
                        FullDiskAccessBanner(model: model)
                        Divider()
                    }
                }
            }
            .sheet(isPresented: $model.isOnboardingPresented) {
                OnboardingSheet(model: model)
            }
    }
}
