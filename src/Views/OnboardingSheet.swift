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
    ///
    /// - Parameter isPresenter: 이 창이 **시트를 띄울 소유 창**인지 (다중 창 T4).
    ///   `FullDiskAccessModel`은 앱 전역 공유 인스턴스라 `isOnboardingPresented`가 `Bool` 하나다.
    ///   이 모디파이어는 창마다 붙으므로 게이팅이 없으면 열린 창 전부가 같은 시트를 동시에 띄운다.
    ///   **배너는 시트와 다른 규칙을 쓴다** — 제한 모드는 모든 창에 해당하는 사실이므로 전 창에 띄우고,
    ///   중복 노출을 피하려고 숨기는 것은 **실제로 시트에 가려지는 소유 창뿐**이다
    ///   (`FullDiskAccessModel.shouldShowBanner(isPresenter:)`).
    func fullDiskAccessOnboarding(_ model: FullDiskAccessModel, isPresenter: Bool = true) -> some View {
        modifier(FullDiskAccessOnboardingModifier(model: model, isPresenter: isPresenter))
    }
}

private struct FullDiskAccessOnboardingModifier: ViewModifier {

    @Bindable var model: FullDiskAccessModel

    /// 이 창이 시트 표시 소유 창인지. 소유 창이 닫히면 `AppEnvironment`가 다음 창에 승계하고,
    /// 승계받은 창은 이 값이 `true`로 바뀌면서 시트를 이어받는다.
    let isPresenter: Bool

    /// 소유 창이 아니면 **읽기는 항상 `false`, 쓰기는 무시**한다.
    /// `.constant(false)`를 쓰지 않는 이유: 소유권이 승계되는 순간 같은 뷰가 그대로
    /// 실제 바인딩으로 전환돼야 하고, 닫기(Esc/[나중에])가 공유 상태에 반영돼야 하기 때문이다.
    private var presentation: Binding<Bool> {
        Binding(
            get: { isPresenter && model.isOnboardingPresented },
            set: { newValue in
                guard isPresenter else { return }
                model.isOnboardingPresented = newValue
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                // 소유 창이 아니면 시트를 못 보므로 배너까지 숨기면 제한 모드를 알 길이 없다(reviewer Major 2).
                if model.shouldShowBanner(isPresenter: isPresenter) {
                    VStack(spacing: 0) {
                        FullDiskAccessBanner(model: model)
                        Divider()
                    }
                }
            }
            .sheet(isPresented: presentation) {
                OnboardingSheet(model: model)
            }
    }
}
