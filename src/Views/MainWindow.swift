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
        //
        // **다중 창 T4**: `isOnboardingPresented`는 앱 전역 공유 `Bool` 하나인데 `.sheet`는
        // 창마다 붙는 모디파이어다. 게이팅이 없으면 열린 창 **전부가 같은 시트를 동시에** 띄운다.
        // 배너는 반대로 전 창 표시가 맞다(제한 모드는 모든 창에 해당하는 사실이다).
        .fullDiskAccessOnboarding(model.fullDiskAccess, isPresenter: model.isOnboardingPresenter)
        // 후속 T3 — 업데이트 확인 결과 알림 3종 (UI설계 §7.9).
        // 시트와 같은 이유로 **소유 창 하나**에만 붙인다(모델은 앱 전역 인스턴스다).
        .updateCheckAlert(model.update, isPresenter: model.isGlobalAlertPresenter)
        // **다중 창 T6a**: 활성 창의 모델을 메뉴에 게시한다. `focusedValue`가 아니라
        // `focusedSceneValue`여야 한다 — 이 앱의 first responder는 `NSTableView`/`NSOutlineView`라
        // SwiftUI 포커스 체인에 뷰가 없어서 `focusedValue`는 값을 영영 게시하지 못하고,
        // File/View/Go 메뉴가 통째로 비활성 상태로 굳는다. 되돌리지 말 것(AppCommands 주석 참조).
        .focusedSceneValue(model)
        // ⌘R의 대상도 함께 게시한다(reviewer minor #8) — 단축키는 `View > Refresh` 하나만 갖고,
        // "무엇을 새로고침할지"는 활성 씬이 정한다. 메인 창은 폴더 목록이다.
        .focusedSceneValue(\.sceneRefresh, SceneRefreshAction(id: "main-\(model.windowID)") { model.refresh() })
        // **다중 창 T3 — 공유 설정 → 이 창의 상태**. `AppSettings`는 앱 전역 1개지만
        // `DirectoryModel`/`TreeModel`은 창마다 자기 사본을 들기 때문에 명시적 동기화가 필요하다
        // (사용자 결정: 숨김/정렬은 즉시 전 창 동기화). 각 sync는 값이 같으면 아무 일도 하지 않고,
        // 설정에 되쓰지 않아 창들 사이에서 왕복하지 않는다.
        .onChange(of: model.settings.showHidden) { model.syncShowHiddenFromSettings() }
        .onChange(of: model.settings.sortDescriptor) { model.syncSortFromSettings() }
        .onChange(of: model.settings.favoritePaths) { model.syncFavoritesFromSettings() }
        .onAppear {
            model.start()
            // 후속 T3 — 앱 시작 시 자동 확인 1회.
            //
            // **`AppModel.start()`가 아니라 여기서 부른다**: `start()`는 단위 테스트가 수백 번
            // 호출하는 경로라, 거기에 네트워크 요청을 심으면 테스트가 실제 GitHub에 붙는다.
            // 뷰의 `onAppear`는 실제 앱에서만 도는 경로다. 프로세스당 1회·24시간 스로틀은
            // `UpdateCheckModel`이 자체 래치로 보장하므로 창이 여러 개여도 요청은 하나다.
            model.update.checkOnLaunchIfNeeded()
        }
        // 창 소유 감시자(FSEvents·볼륨) 해제 + 공유 감시자(클립보드·FDA) 소유권 반납.
        // M1 백로그였던 `stopObservingVolumes` 정리 지점이기도 하다.
        .onDisappear { model.stop() }
    }
}
