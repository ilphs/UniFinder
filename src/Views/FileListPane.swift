import SwiftUI

/// 우측 pane 컨테이너 — 목록 브릿지 + 상태별 empty-state (UI설계 §4.2).
struct FileListPane: View {

    @Bindable var model: AppModel

    /// 다중 창 T7 — 컨텍스트 메뉴의 "Open in New Window" 진입점.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            FileListBridge(
                items: model.directory.items,
                revision: model.directory.revision,
                contentsRevision: model.directory.contentsRevision,
                sortDescriptor: model.directory.sortDescriptor,
                selection: Binding(
                    get: { model.directory.selection },
                    set: { model.directory.selection = $0 }
                ),
                cutURLs: model.clipboard.cutURLs,
                clipboardRevision: model.clipboard.revision,
                canPaste: model.canPaste,
                renameRequest: model.renameRequest,
                currentDirectory: model.navigation.currentURL,
                isOperationInProgress: model.isOperationInProgress,
                isTextEditing: model.isTextEditing,
                focusBroker: model.focusBroker,
                settings: model.settings,
                onOpen: { model.open($0) },
                onNavigateUp: { model.goUp(source: .list) },
                onSortChange: { model.toggleSort(for: $0) },
                onRefresh: { model.refresh() },
                onTypeAhead: { _ in },
                // 패널 토글은 브릿지가 소유한다(B15). 이 콜백은 상위가 필요할 때 쓰는 알림 지점이다.
                onQuickLook: {},
                onDrop: { urls, destination, operation in
                    // B9 — 드롭 실행의 단일 진입점.
                    model.drop(urls, into: destination, operation: operation)
                },
                onApplySort: { model.applySort($0) },
                onCopy: { model.copy() },
                onCut: { model.cut() },
                onPaste: { model.pasteIntoCurrentFolder() },
                onDelete: { model.trashSelection() },
                onNewFolder: { model.createFolderInCurrentDirectory() },
                onRevealInFinder: { model.revealInFinder() },
                isFavorite: { model.isFavorite($0) },
                onToggleFavorite: { model.toggleFavorite($0) },
                onOpenInNewWindow: { url in
                    openWindow(id: UniFinderApp.mainWindowID, value: WindowSeed(folderURL: url))
                },
                onBeginRename: { model.requestRename($0) },
                onValidateRename: { model.validateRename($0, to: $1) },
                onCommitRename: { model.rename($0, to: $1) },
                onRenamingChanged: { model.isRenaming = $0 }
            )

            overlay
        }
        .frame(minWidth: 400)
    }

    @ViewBuilder
    private var overlay: some View {
        if let error = model.directory.error {
            // 접근 불가 화면에만 [How to Grant Access] 버튼이 있다 — 그 버튼만 클릭을 받는다.
            emptyState(interactive: error == .accessDenied) {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(error.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(error.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if error == .accessDenied {
                        Text("Allow UniFinder in System Settings > Privacy & Security > Full Disk Access.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                        // M1은 문구만 있었고, M3 T5에서 온보딩 시트(딥링크 포함)로 연결한다.
                        Button("How to Grant Access") { model.fullDiskAccess.present() }
                            .padding(.top, 4)
                    }
                }
            }
        } else if model.directory.isLoading {
            emptyState {
                ProgressView()
                    .controlSize(.small)
            }
        } else if model.directory.items.isEmpty {
            emptyState {
                Text("This folder is empty.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// empty-state 오버레이 — **배경은 클릭을 통과시키고, 내용(버튼)만 클릭을 받는다**.
    ///
    /// 예전에는 `interactive:` 파라미터로 오버레이 **전체**의 히트 테스트를 켰다. 그러면
    /// 접근 불가 화면에서 (a) 빈 영역 우클릭 메뉴가 열리지 않고 (b) 클릭으로 목록에 포커스를 줄 수
    /// 없어 `Backspace`(상위 이동)·`F5`(새로 고침)가 마우스 사용자에게 영영 닿지 않았다
    /// (M3 리뷰 권장 3). 배경 `Rectangle`은 그리기 전용으로 두고, 버튼이 든 `content()`만
    /// 히트 테스트 대상으로 남긴다.
    /// - Parameter interactive: 버튼이 있는 화면(`.accessDenied`)에서만 `true`.
    ///   `true`여도 클릭을 받는 것은 **버튼이 든 내용뿐**이고 배경은 언제나 목록으로 통과시킨다.
    private func emptyState<Content: View>(
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            // 배경은 그리기 전용 — 목록의 우클릭/포커스 클릭을 가로채지 않는다.
            Rectangle()
                .fill(Color(nsColor: .textBackgroundColor))
                .allowsHitTesting(false)
            content()
                .allowsHitTesting(interactive)
        }
    }
}

/// 좌측 pane 컨테이너.
struct SidebarPane: View {

    @Bindable var model: AppModel

    /// 다중 창 T7 — 트리 컨텍스트 메뉴의 "Open in New Window" 진입점.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SidebarTreeBridge(
            model: model.tree,
            revision: model.tree.revision,
            sectionsRevision: model.tree.sectionsRevision,
            focusBroker: model.focusBroker,
            canPaste: model.canPaste,
            renameRequest: model.renameRequest,
            isOperationInProgress: model.isOperationInProgress,
            onDrop: { urls, destination, operation in
                // 목록과 **같은** 드롭 진입점 (B9).
                model.drop(urls, into: destination, operation: operation)
            },
            onSelect: { model.navigate(to: $0, source: .tree) },
            onRefresh: { model.refresh() },
            onCopy: { model.copy([$0]) },
            onPaste: { model.paste(into: $0) },
            onDelete: { url in model.trash([url], in: url.deletingLastPathComponent()) },
            onNewFolder: { model.createFolder(in: $0) },
            onBeginRename: { model.requestRename($0) },
            onValidateRename: { model.validateRename($0, to: $1) },
            onCommitRename: { model.rename($0, to: $1) },
            onRenamingChanged: { model.isRenaming = $0 },
            isFavorite: { model.isFavorite($0) },
            onToggleFavorite: { model.toggleFavorite($0) },
            onOpenInNewWindow: { url in
                openWindow(id: UniFinderApp.mainWindowID, value: WindowSeed(folderURL: url))
            }
        )
        .frame(minWidth: 180, idealWidth: model.settings.sidebarWidth, maxWidth: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
