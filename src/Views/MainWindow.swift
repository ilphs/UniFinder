import SwiftUI

/// 메인 윈도우 셸 — 툴바 / 2-pane 스플릿 / 상태바 (설계서 §2, UI설계 §1).
struct MainWindow: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ToolbarBar(model: model)
            Divider()

            HSplitView {
                SidebarPane(model: model)
                FileListPane(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 진행률은 시트가 아니라 **비모달 오버레이**다 (m3-impl T2/B18) —
            // 카드 밖 영역은 클릭이 그대로 통과해 작업 중에도 탐색이 가능하다.
            .overlay(alignment: .bottom) {
                OperationProgressOverlay(
                    progress: model.operationProgress,
                    onCancel: { model.cancelCurrentOperation() }
                )
            }

            Divider()
            StatusBarView(model: model)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(
            // F5 새로고침 — 메뉴 단축키로 표현하기 어려운 키만 숨김 버튼으로 등록 (T7)
            Button("") { model.refresh() }
                .keyboardShortcut(KeyEquivalent(KeyScalar.f5Character), modifiers: [])
                .hidden()
        )
        // M3 T5 — FDA 웰컴 시트 + 제한 모드 배너 (구현은 OnboardingSheet.swift)
        .fullDiskAccessOnboarding(model.fullDiskAccess)
        .onAppear { model.start() }
        // 감시자(FSEvents·볼륨·클립보드·FDA) 해제 — M1 백로그였던 `stopObservingVolumes` 정리 지점.
        .onDisappear { model.stop() }
    }
}
