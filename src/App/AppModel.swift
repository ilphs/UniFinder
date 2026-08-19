import AppKit
import Foundation
import Observation
import QuickLookUI
import UniformTypeIdentifiers

/// 윈도우 1개분의 상태를 묶어 ViewModel들을 조합한다 (설계서 §3.3 흐름의 진입점).
///
/// 사용자 액션 → `NavigationModel.navigate` → `DirectoryModel.load` → `TreeModel.reveal`
/// 순서를 이 타입이 단일하게 소유해서, 트리·주소창·목록이 항상 같은 경로를 가리키게 한다.
///
/// **다중 창 규약 (T3)** — "윈도우 1개분"은 이제 전제가 아니라 **실제 구조**다.
/// 씬이 `WindowGroup`이라 창마다 이 인스턴스가 하나씩 생기고(`MainWindowRoot`가 만든다),
/// 탐색·트리·히스토리·선택·진행 중 조작은 **창 안에 갇힌다**.
///
/// 창을 넘어 하나여야 하는 것(설정·클립보드·FDA)은 `AppEnvironment`가 소유하고 여기서는
/// 그 인스턴스를 **빌려 쓴다**. 그래서 `stop()`은 공유 감시자를 무조건 끊지 않고
/// **자기 창의 소유권만 반납**한다(소유자 집합 — `ClipboardModel`/`FullDiskAccessModel` 참조).
///
/// **직렬화 범위**: `runOperation`의 "동시 2건 금지"는 앱 전역이 아니라 **창 단위**다.
/// 근거는 `ref-docs/specs/impl/unifinder-multiwindow-impl.md` §직렬화 범위.
@Observable
@MainActor
final class AppModel {

    /// 이동 요청의 출처. 이동 후 first responder를 어디에 둘지 결정하는 유일한 근거다 (UI설계 §9).
    ///
    /// 트리에서 방향키로 이동하면 `NSOutlineView`의 선택 변경 → `navigate(to:source:.tree)`가
    /// 연쇄적으로 발생한다. 이때 포커스를 목록으로 옮기면 다음 방향키를 트리가 받지 못해
    /// 트리 키보드 탐색이 아예 불가능해지므로, 트리가 이미 first responder면 포커스를 유지한다.
    enum NavigationSource {
        /// 우측 목록(더블클릭 / Enter / Backspace 상위이동)
        case list
        /// 좌측 트리(마우스 선택 / 방향키 / Enter)
        case tree
        /// 툴바 버튼 · 메뉴 · 단축키(뒤로/앞으로/위/새로고침)
        case toolbar
        /// 주소창 breadcrumb 클릭 · 경로 직접 입력
        case breadcrumb
        /// 앱 시작 시 최초 로드
        case startup
    }

    /// 이 창의 식별자 (다중 창 T3). 공유 자원의 **소유자 토큰**으로 쓴다 —
    /// `AppEnvironment.register`/`unregister`, 클립보드·FDA 감시자 소유자 집합이 이 값을 센다.
    let windowID = UUID()

    /// 앱 전역 상태(설정·클립보드·FDA)와 창 목록의 소유자.
    ///
    /// **기본값은 `.shared`가 아니다** — `init(environment:)`에 `nil`을 주면 격리된 새 환경을
    /// 만든다. 테스트가 `UserDefaults.standard`/`NSPasteboard.general`을 공유하지 않게 하기 위함이며,
    /// 공유 인스턴스는 `MainWindowRoot`(= 실제 앱 경로)에서만 주입한다.
    @ObservationIgnored
    let environment: AppEnvironment

    let settings: AppSettings
    let navigation: NavigationModel
    let directory: DirectoryModel
    let tree: TreeModel

    /// 복사/잘라내기 상태 (M2 T3). `AppModel`이 소유한다 — architect B1.
    let clipboard: ClipboardModel

    /// FDA 온보딩 상태 (M3 T5). 감지·시트·배너는 전부 이 모델이 소유한다.
    let fullDiskAccess: FullDiskAccessModel

    /// 파일 조작 서비스 (M2 T0). 프로토콜로 주입받아 테스트가 실 파일시스템에 묶이지 않게 한다.
    @ObservationIgnored
    let operations: any FileOperating

    /// 이름 충돌 시트 프레젠터. `FileOperations`는 `ConflictResolving`으로만 안다.
    @ObservationIgnored
    let conflictPresenter = ConflictSheetPresenter()

    @ObservationIgnored
    let focusBroker = FocusBroker()

    /// 주소창 편집 모드 여부 (UI설계 §2.2).
    /// 편집 중에는 목록/트리가 first responder가 아니므로 브릿지 단축키가 자연히 비활성화된다(T7).
    var isAddressEditing = false {
        didSet { focusBroker.isAddressEditing = isAddressEditing }
    }

    /// 인라인 이름 변경 중인지 (M2 T5 / architect B7).
    /// 편집 중에는 refresh/reveal/포커스 강제 이동과 앱 단축키를 억제한다.
    var isRenaming = false {
        didSet {
            focusBroker.isRenaming = isRenaming
            // 편집이 끝났으면 그동안 보류한 외부 변경을 1회 반영한다 (m3-impl T0).
            if oldValue, !isRenaming { flushPendingExternalChange() }
        }
    }

    /// 텍스트 필드가 키 입력을 소유하고 있는지 (주소창 편집 또는 인라인 rename).
    ///
    /// **메뉴 key equivalent는 responder chain보다 먼저 잡힌다** — 이 값이 `true`인 동안
    /// `AppCommands`의 `Cmd+C/X/V` 항목을 비활성화해야 텍스트 필드의 기본 복사/붙여넣기가
    /// 정상 동작한다 (m2-impl T2).
    var isTextEditing: Bool { isAddressEditing || isRenaming }

    /// 목록/트리에 "이 항목의 인라인 편집을 시작하라"고 지시하는 1회성 토큰 (M2 T5·T6).
    /// F2·컨텍스트 메뉴·새 폴더 생성 직후가 **모두 이 경로 하나**를 쓴다.
    private(set) var renameRequest: RenameRequest?

    struct RenameRequest: Equatable {
        let url: URL
        /// 같은 URL을 연속으로 요청해도 브릿지가 구분할 수 있게 하는 일련번호.
        let token: Int
    }

    /// 상태바 미니 진행 표시 (UI설계 §5). `nil`이 아니면 조작이 진행 중이라는 뜻이다.
    private(set) var operationProgressText: String?

    /// 진행률 오버레이 상태 (m3-impl T2). **시트가 아니라 비모달 오버레이**다(B18).
    let operationProgress: OperationProgressModel

    /// 파일 조작이 진행 중인지 — 드롭 검증(B12)이 이 값으로 드롭 자체를 거부한다.
    ///
    /// **`operationTask != nil` 계산 속성이면 안 된다**: `operationTask`는 `@ObservationIgnored`라
    /// 값이 바뀌어도 SwiftUI가 뷰를 다시 만들지 않고, 브릿지에는 조작 시작 이전의 낡은 `false`가
    /// 남는다 — 그러면 조작 중에도 드롭이 접수되어 "드롭 성공 후 아무 일도 없음"이 된다(B12 무력화).
    private(set) var isOperationInProgress = false

    /// 진행 중인 파일 조작. 동시에 2건이 돌면 충돌 시트가 겹치므로 1건으로 직렬화한다.
    @ObservationIgnored
    private var operationTask: Task<Void, Never>?

    @ObservationIgnored
    private var renameTokenCounter = 0

    @ObservationIgnored
    private var didStart = false

    /// 트리에 마지막으로 반영한 즐겨찾기 목록 (다중 창 T3 / reviewer m3).
    /// `syncFavoritesFromSettings()`가 중복 반영을 걸러내는 기준이다.
    @ObservationIgnored
    private var appliedFavoritePaths: [String] = []

    /// 진행 중인 트리 reveal. 다음 이동이 오면 취소해 스테일한 선택이 뒤늦게 덮어쓰지 않게 한다.
    @ObservationIgnored
    private var revealTask: Task<Void, Never>?

    /// 표시 중 폴더의 외부 변경 감시 (m3-impl T0). **소유자를 `AppModel`로 둔 이유**는
    /// 네비게이션 시점을 아는 유일한 지점이기 때문이다(B8).
    ///
    /// 이것은 **외부 변경 전용 보조 경로**다(B7) — 조작 결과 반영(트리 무효화·폴더 소실 판정·
    /// 결과 항목 선택)은 `applyOperationResult`가 그대로 담당한다. FSEvents는 표시 중 폴더만
    /// 감시하므로 트리나 잘라내기 원본의 부모 폴더 갱신을 대체할 수 없다.
    @ObservationIgnored
    let directoryWatcher: DirectoryWatcher

    /// 확인 시트가 떠 있는지 (m3-impl T0/B23).
    ///
    /// 시트가 떠 있는 동안에도 메인 큐 콜백(FSEvents 갱신)은 계속 실행되므로, 이 가드가 없으면
    /// 사용자가 알림을 보고 있는 사이에 뒤쪽 목록이 통째로 갈아엎힌다.
    @ObservationIgnored
    private var isShowingModal = false

    /// 보류된 외부 변경 (편집/모달 중에 도착). 상태가 풀리면 1회만 반영한다.
    @ObservationIgnored
    private var hasPendingExternalChange = false

    /// 마지막으로 감시를 건 폴더. 보류 중인 외부 변경을 **폴더가 실제로 바뀔 때만** 버리기 위한 기준이다.
    @ObservationIgnored
    private var watchedURL: URL?
    /// 주소창 입력이 잘못됐을 때 셰이크 애니메이션을 트리거하는 카운터
    private(set) var addressShakeTrigger = 0

    /// 상태바에 5초간 띄우는 안내 문구 (UI설계 §8 — 모달 금지)
    private(set) var transientMessage: String?
    private var messageTask: Task<Void, Never>?

    /// Open With 실행·후보 조회 (후속 T4). 컨텍스트 메뉴 서브메뉴와 Get Info 창이 공유한다.
    @ObservationIgnored
    var openWithService = OpenWithService()

    /// "Other…"에서 앱을 고르는 경로 — `NSOpenPanel` 주입점(`FullDiskAccessModel.opener` 선례).
    /// 테스트가 실제 패널을 띄우지 않게 한다. `nil`을 돌려주면 사용자가 취소한 것이다.
    @ObservationIgnored
    var applicationChooser: @MainActor () -> URL? = AppModel.presentApplicationOpenPanel

    /// `settings`/`startURL`의 기본값 생성은 MainActor 격리가 필요해 본문에서 만든다.
    ///
    /// - Parameter environment: 앱 전역 상태의 소유자. **`nil`이면 격리된 새 환경을 만든다** —
    ///   기본값을 `AppEnvironment.shared`로 두면 61개 테스트 호출부가 전부 `UserDefaults.standard`와
    ///   `NSPasteboard.general`을 공유하게 되어 테스트 간 오염이 생긴다(현재 테스트들은
    ///   `UserDefaults(suiteName:)`와 전용 pasteboard로 격리 중이다). 공유 인스턴스 주입은
    ///   `MainWindowRoot`가 하는 일이다.
    ///   `environment`와 개별 인자(`settings`/`clipboard`/`fullDiskAccess`)를 함께 주면
    ///   **개별 인자가 이긴다**(테스트가 환경 일부만 갈아끼울 수 있도록).
    init(
        environment: AppEnvironment? = nil,
        settings: AppSettings? = nil,
        loader: any DirectoryListing = DirectoryLoader.shared,
        operations: any FileOperating = FileOperations.shared,
        clipboard: ClipboardModel? = nil,
        fullDiskAccess: FullDiskAccessModel? = nil,
        directoryWatcher: DirectoryWatcher? = nil,
        operationProgress: OperationProgressModel? = nil,
        startURL: URL? = nil
    ) {
        // 환경이 없으면 **이 인스턴스 전용** 환경을 만든다(위 주석 — `.shared` 오염 금지).
        // 개별 인자가 주어졌으면 그것을 환경 구성에 그대로 싣는다.
        let environment = environment ?? AppEnvironment(
            settings: settings,
            clipboard: clipboard,
            fullDiskAccess: fullDiskAccess
        )
        let settings = settings ?? environment.settings
        let startURL = startURL ?? FileManager.default.homeDirectoryForCurrentUser
        let start = NavigationModel.normalize(startURL)
        self.environment = environment
        self.settings = settings
        self.operations = operations
        self.clipboard = clipboard ?? environment.clipboard
        self.fullDiskAccess = fullDiskAccess ?? environment.fullDiskAccess
        self.directoryWatcher = directoryWatcher ?? DirectoryWatcher()
        self.operationProgress = operationProgress ?? OperationProgressModel()
        self.navigation = NavigationModel(startURL: start)
        self.directory = DirectoryModel(
            loader: loader,
            sortDescriptor: settings.sortDescriptor,
            showHidden: settings.showHidden
        )
        self.tree = TreeModel(loader: loader, showHidden: settings.showHidden, settings: settings)
        // `TreeModel`이 이미 이 목록으로 섹션을 만든 상태다 — 첫 `.onChange`가 헛돌지 않게 맞춰 둔다.
        self.appliedFavoritePaths = settings.favoritePaths

        focusBroker.beginAddressEditing = { [weak self] in
            self?.isAddressEditing = true
        }
        // 충돌 시트는 목록/트리가 붙어 있는 윈도우에 띄운다(테스트에서는 윈도우가 없어 취소로 응답).
        conflictPresenter.windowProvider = { [focusBroker] in focusBroker.window }

        // m3-impl T0 — 외부 변경 감시 콜백. 표시 중 폴더가 사라지면 상위로 자동 이동한다(설계서 §6).
        self.directoryWatcher.onChange = { [weak self] url in
            self?.handleExternalChange(at: url)
        }
        self.directoryWatcher.onVanished = { [weak self] url in
            self?.handleWatchedDirectoryVanished(at: url)
        }
        // m3-impl T1 — 표시 중이던 볼륨이 분리되면 홈으로 이동한다(트리 갱신은 TreeModel이 담당).
        self.tree.onVolumeUnmounted = { [weak self] volumeURL in
            self?.handleVolumeUnmounted(volumeURL)
        }
    }

    /// 창이 열릴 때 1회 — 첫 폴더 로드 + 트리 동기화 + 볼륨/클립보드 감시 시작.
    ///
    /// **공유 자원 등록은 `guard !didStart` 안쪽에서만 한다**(권장 7): SwiftUI가 뷰 아이덴티티
    /// 변화로 `onAppear`를 추가로 부를 수 있는데, 그때마다 등록이 늘면 소유자 집합이 아니라
    /// 카운트였다면 그대로 누수가 된다. 집합 + 이 가드가 이중 안전망이다.
    func start() {
        guard !didStart else { return }
        didStart = true
        environment.register(windowID)
        tree.startObservingVolumes()
        // architect B6 — 상시 폴링 대신 앱 재활성화 시점에만 changeCount를 비교한다.
        // 다중 창 T1 — 공유 인스턴스라 소유자를 실어 보낸다(첫 창에서만 실제 등록).
        clipboard.startObservingPasteboard(owner: windowID)
        // M3 T5 — FDA 감지 + 필요 시 웰컴 시트 (재감지도 didBecomeActive 시점을 공유한다).
        fullDiskAccess.start(owner: windowID)
        loadCurrent(source: .startup)
    }

    /// 윈도우가 닫힐 때 감시자를 전부 해제한다.
    ///
    /// M1 백로그였던 `stopObservingVolumes` 미호출 건을 여기서 정리한다 (m3-impl T1) —
    /// M3에서 감시자가 3종(볼륨·클립보드·FDA)에 FSEvents까지 늘어나 해제 경로가 반드시 필요하다.
    /// **다중 창 T3**: 클립보드·FDA는 앱 전역 공유 인스턴스라 이 창의 소유권만 반납한다 —
    /// 마지막 창이 반납할 때만 실제로 감시가 풀린다. FSEvents·볼륨 감시는 창 소유라 그대로 끊는다.
    func stop() {
        guard didStart else { return }
        didStart = false
        environment.unregister(windowID)
        directoryWatcher.stop()
        tree.stopObservingVolumes()
        clipboard.stopObservingPasteboard(owner: windowID)
        fullDiskAccess.stopObservingActivation(owner: windowID)
        // QuickLook 패널은 **앱에 하나뿐인 공유 패널**이다. 배경 창 하나를 닫았다고 무조건 닫으면
        // 다른 창이 띄운 미리보기가 함께 사라진다 — 마지막 창이 닫힐 때만 정리한다.
        if !environment.hasOpenWindows {
            Self.closeQuickLookPanelIfOpen()
        }
    }

    /// 창이 닫힐 때 남아 있는 QuickLook 패널을 닫는 **방어선** (M3 리뷰 blocker 3).
    ///
    /// 1차 방어는 `FileListBridge.dismantleNSView`(패널의 dataSource/delegate까지 끊는다)이고,
    /// 여기는 그 경로가 어떤 이유로 돌지 않았을 때를 위한 2차선이다. 패널의 dataSource/delegate는
    /// `assign` 속성이라 소유자가 해제돼도 nil이 되지 않는다 — 열린 패널을 남겨두면 안 된다.
    private static func closeQuickLookPanelIfOpen() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible
        else { return }
        panel.orderOut(nil)
    }

    // MARK: - 이동

    /// 모든 이동 수단(트리 선택 / 더블클릭 / 주소창 / 히스토리)의 단일 진입점.
    func navigate(to url: URL, source: NavigationSource = .list) {
        let resolved = Self.nearestExistingDirectory(NavigationModel.normalize(url))
        if resolved != NavigationModel.normalize(url) {
            showMessage("The folder couldn't be found. Moved to the enclosing folder.")
        }
        guard resolved != navigation.currentURL else {
            // 같은 폴더 재선택은 재열거만 수행하지 않고 무시한다(불필요한 깜빡임 방지)
            return
        }
        navigation.navigate(to: resolved)
        loadCurrent(source: source)
    }

    func goBack(source: NavigationSource = .toolbar) {
        guard navigation.canGoBack else { return }
        navigation.goBack()
        loadCurrent(source: source)
    }

    func goForward(source: NavigationSource = .toolbar) {
        guard navigation.canGoForward else { return }
        navigation.goForward()
        loadCurrent(source: source)
    }

    func goUp(source: NavigationSource = .toolbar) {
        guard navigation.canGoUp else { return }
        navigation.goUp()
        loadCurrent(source: source)
    }

    /// 새로고침 — 현재 폴더 재열거, 선택은 URL 기준으로 유지 (T6).
    /// 현재 폴더가 사라졌다면 가장 가까운 상위 폴더로 이동한다 (설계서 §6).
    func refresh() {
        // 인라인 편집 중 재열거하면 편집 중인 셀이 통째로 사라진다 (architect B7 — `isRenaming` 가드)
        guard !isRenaming else { return }
        let current = navigation.currentURL
        let existing = Self.nearestExistingDirectory(current)
        if existing != current {
            navigation.replaceCurrent(with: existing)
            showMessage("The folder no longer exists. Moved to the enclosing folder.")
            loadCurrent(source: .toolbar)
            return
        }
        tree.rebuildSections()
        directory.reload()
        startReveal(navigation.currentURL)
    }

    private func loadCurrent(source: NavigationSource) {
        let url = navigation.currentURL
        directory.load(url: url)
        syncWatcher()
        startReveal(url)
        if shouldMoveFocusToList(for: source) {
            focusBroker.focusListSoon()
        }
    }

    // MARK: - 외부 변경 감시 (m3-impl T0)

    /// 감시 대상을 현재 표시 폴더로 맞춘다. 같은 폴더면 `DirectoryWatcher`가 무시한다.
    private func syncWatcher() {
        // 보류 중이던 외부 변경은 **표시 폴더가 실제로 바뀔 때만** 의미를 잃는다.
        // 무조건 리셋하면 같은 폴더에 감시를 다시 거는 경로(폴더 재생성 등)에서
        // 아직 반영하지 못한 갱신을 근거 없이 버리게 된다(M3 리뷰 권장 2 연관).
        if !PathKey.isSame(watchedURL ?? navigation.currentURL, navigation.currentURL) {
            hasPendingExternalChange = false
        }
        watchedURL = navigation.currentURL
        directoryWatcher.watch(navigation.currentURL)
    }

    /// 외부 변경 반영을 미뤄야 하는 상태.
    ///
    /// - 인라인 편집 중: 재열거하면 편집 중인 셀이 통째로 사라진다(architect B7과 같은 규칙)
    /// - 확인 시트 표시 중: 시트 뒤에서 목록이 갈아엎힌다(m3-impl B23)
    private var isExternalRefreshSuspended: Bool { isRenaming || isShowingModal }

    /// 확인 시트가 떠 있는 동안 외부 변경 반영을 보류하고, **닫힌 뒤에** 1회 반영한다 (B23).
    ///
    /// **`defer`로 해제하면 안 된다** (M2 백로그 — `runModal` → 시트 전환의 유일한 함정):
    /// 앱-모달 런루프는 사용자가 버튼을 누를 때까지 `runModal()` 안에서 블록되므로 `defer`가
    /// 곧 "시트가 닫힌 시점"이었다. 시트는 런루프를 블록하지 않아 표시 요청 직후 함수가 반환하므로,
    /// 같은 자리에서 `defer`를 쓰면 시트가 뜨자마자 가드가 풀려 보류 규약이 통째로 무력화된다.
    /// 해제는 반드시 시트 완료 콜백이 도착한 뒤(= `body`의 `await`가 재개된 뒤)여야 한다.
    func withExternalRefreshSuspended<T>(_ body: () async -> T) async -> T {
        isShowingModal = true
        let value = await body()
        isShowingModal = false
        flushPendingExternalChange()
        return value
    }

    private func handleExternalChange(at url: URL) {
        // 감시 통지와 현재 폴더가 어긋났으면(이동 직후 도착한 이벤트) 버린다.
        guard PathKey.isSame(url, navigation.currentURL) else { return }
        guard !isExternalRefreshSuspended else {
            hasPendingExternalChange = true
            return
        }
        // in-place 갱신 — 스크롤·선택 유지, `pendingSelectionKeys` 미소비(B5·B6)
        directory.refreshContents()
    }

    private func flushPendingExternalChange() {
        guard hasPendingExternalChange, !isExternalRefreshSuspended else { return }
        hasPendingExternalChange = false
        directory.refreshContents()
    }

    /// 표시 중 폴더 자체가 삭제/이동됨 — 가장 가까운 상위로 내려간다 (설계서 §6, 모달 없이 상태바 안내).
    private func handleWatchedDirectoryVanished(at url: URL) {
        guard PathKey.isSame(url, navigation.currentURL) else { return }
        let existing = Self.nearestExistingDirectory(url)
        guard !PathKey.isSame(existing, url) else {
            // 같은 경로가 다시 만들어진 경우 — 감시를 다시 걸고 **내용도 다시 읽는다**.
            //
            // 감시만 다시 걸면(M3 리뷰 권장 2) 폴더가 교체된 상황에서 화면은 사라진 옛 폴더의
            // 내용을 그대로 들고 스테일해진다. `refreshContents()`는 스크롤·선택을 유지하는
            // in-place 갱신이라 여기서 부르는 비용이 낮다(B5).
            syncWatcher()
            guard !isExternalRefreshSuspended else {
                // 편집/모달 중이면 다른 외부 변경과 같은 규칙으로 보류했다가 1회 반영한다(B7·B23).
                hasPendingExternalChange = true
                return
            }
            directory.refreshContents()
            return
        }
        navigation.replaceCurrent(with: existing)
        showMessage("The folder no longer exists. Moved to the enclosing folder.")
        tree.invalidate(existing)
        loadCurrent(source: .toolbar)
    }

    /// 이전 reveal은 취소하고 새 reveal만 남긴다.
    /// (취소 없이 쌓이면 연속 이동 시 같은 노드에 대한 확장이 중첩돼 트리 인덱스가 스테일해진다)
    private func startReveal(_ url: URL) {
        // 편집 중 트리 확장/선택이 끼어들면 field editor가 걷힌다 (architect B7)
        guard !isRenaming else { return }
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            await self?.tree.reveal(url)
        }
    }

    /// 이동 후 포커스를 목록으로 옮길지 여부.
    /// 트리에서 시작된 이동인데 트리가 이미 first responder면 포커스를 빼앗지 않는다(방향키 탐색 유지).
    private func shouldMoveFocusToList(for source: NavigationSource) -> Bool {
        // 인라인 편집 중에는 어떤 경로로도 포커스를 빼앗지 않는다 (architect B7)
        guard !isRenaming else { return false }
        guard source == .tree else { return true }
        return !focusBroker.isTreeFocused
    }

    // MARK: - 볼륨 마운트/언마운트 (m3-impl T1)

    /// 언마운트된 볼륨 하위를 보고 있었으면 홈으로 이동한다 (설계서 §6, 모달 없이 상태바 안내).
    func handleVolumeUnmounted(_ volumeURL: URL?) {
        guard Self.shouldLeaveUnmountedVolume(current: navigation.currentURL, unmounted: volumeURL) else { return }
        showMessage("The volume was ejected. Moved to your home folder.")
        navigate(to: FileManager.default.homeDirectoryForCurrentUser, source: .toolbar)
    }

    /// 표시 중 경로를 떠나야 하는지 — 뷰 없이 단위 테스트할 수 있도록 순수 판정으로 분리한다.
    ///
    /// 볼륨 URL을 실어주지 않는 통지도 있으므로, 그때는 **현재 경로가 아직 존재하는지**로 판단한다
    /// (언마운트되면 마운트 포인트가 통째로 사라진다).
    nonisolated static func shouldLeaveUnmountedVolume(current: URL, unmounted: URL?) -> Bool {
        if let unmounted, PathKey.isSameOrDescendant(current, of: unmounted) { return true }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory)
        return !(exists && isDirectory.boolValue)
    }

    // MARK: - 열기

    /// 목록에서 Enter/더블클릭으로 항목을 연다.
    /// 폴더(심볼릭 링크 폴더 포함)는 진입, 파일은 기본 앱으로 실행한다.
    func open(_ items: [FileItem]) {
        guard !items.isEmpty else { return }

        if let folder = items.first(where: { $0.isDirectory }), items.count == 1 || items.allSatisfy(\.isDirectory) {
            navigate(to: Self.resolveTarget(of: folder), source: .list)
            return
        }

        for item in items where !item.isDirectory {
            NSWorkspace.shared.open(item.url)
        }
    }

    func openSelection() {
        open(directory.selectedItems)
    }

    /// 심볼릭 링크 폴더는 타겟으로 이동한다 (설계서 §6).
    ///
    /// "Open in New Window"(다중 창 T7)도 **같은 규칙**으로 대상을 해석해야 한다 —
    /// 같은 항목을 여는데 진입점에 따라 링크와 타겟으로 갈리면 안 된다.
    ///
    /// **예외: Get Info는 이 함수를 쓰지 않는다** (2026-08-19 / D3 · 설계서 §6 규약).
    /// `Open`은 **의도**를 다루므로 링크를 따라가지만 Get Info는 **관찰**을 다룬다. 링크 파일의
    /// 정보를 물은 사용자에게 타겟의 크기·날짜를 답하면 다른 질문에 답하는 것이다. 그래서
    /// `InfoTarget`/`ItemInfoModel`은 링크를 해석하지 않고 `Original:` 행에 경로만 병기한다.
    /// 이 예외는 `InfoTargetSymlinkTests`가 소스 수준에서까지 봉인한다.
    static func resolveTarget(of item: FileItem) -> URL {
        guard item.isSymlink else { return item.url }
        return item.url.resolvingSymlinksInPath()
    }

    // MARK: - 정렬 / 숨김 (T6)

    func toggleSort(for key: SortKey) {
        directory.toggleSort(for: key)
        settings.sortDescriptor = directory.sortDescriptor
    }

    /// 컨텍스트 메뉴에서 기준/방향을 직접 지정하는 경로 (M2 T7 — 헤더 클릭 토글과 구분).
    func applySort(_ descriptor: FileSortDescriptor) {
        directory.applySort(descriptor)
        settings.sortDescriptor = directory.sortDescriptor
    }

    func toggleHiddenItems() {
        let newValue = !settings.showHidden
        settings.showHidden = newValue
        directory.setShowHidden(newValue)
        tree.showHidden = newValue
        tree.rebuildSections()
        startReveal(navigation.currentURL)
    }

    // MARK: - 공유 설정 → 창 상태 동기화 (다중 창 T3)

    /// `AppSettings`는 앱 전역 1개인데 `DirectoryModel`/`TreeModel`은 **창마다** 자기 사본을 든다.
    /// 그래서 창 A의 설정 변경이 창 B의 화면까지 닿게 하려면 명시적 동기화가 필요하다
    /// (사용자 결정: 숨김/정렬은 **즉시 전 창 동기화**). `MainWindow`의 `.onChange`가 부른다.
    ///
    /// **설정에 되쓰면 안 된다** — `directory.setShowHidden`이 `settings.showHidden`을 다시
    /// 건드리면 `.onChange`가 다시 돌아 창들 사이에서 무한 왕복이 된다. 여기서는 **설정 → 창**
    /// 한 방향만 흐르고, 반대 방향은 `toggleHiddenItems`/`toggleSort`/`applySort`가 담당한다.
    func syncShowHiddenFromSettings() {
        let newValue = settings.showHidden
        guard directory.showHidden != newValue || tree.showHidden != newValue else { return }
        directory.setShowHidden(newValue)
        tree.showHidden = newValue
        tree.rebuildSections()
        startReveal(navigation.currentURL)
    }

    func syncSortFromSettings() {
        let descriptor = settings.sortDescriptor
        guard directory.sortDescriptor != descriptor else { return }
        directory.applySort(descriptor)
    }

    /// 즐겨찾기는 트리 섹션 구성 자체를 바꾼다.
    ///
    /// **스냅샷 가드가 필요한 이유** (reviewer m3): 즐겨찾기를 토글한 창은 `addFavorite`/`removeFavorite`
    /// 안에서 이미 반영을 마쳤는데, 그 직후 `.onChange(of: settings.favoritePaths)`가 같은 창에도
    /// 도착해 한 번 더 돈다. `startReveal`은 진행 중이던 `revealTask`를 취소하므로 방금 시작한
    /// reveal이 즉시 취소·재시작되고, 창이 N개면 N+1회 돈다. 마지막으로 반영한 목록과 같으면 건너뛴다.
    func syncFavoritesFromSettings() {
        guard appliedFavoritePaths != settings.favoritePaths else { return }
        applyFavoriteSections()
    }

    /// 이 창이 FDA 온보딩 시트를 띄울 소유 창인지 (다중 창 T4/필수4).
    /// `FullDiskAccessModel.isOnboardingPresented`는 공유 `Bool` 하나라, 게이팅이 없으면
    /// 열려 있는 모든 창이 같은 시트를 동시에 띄운다.
    var isOnboardingPresenter: Bool {
        environment.isOnboardingPresenter(windowID)
    }

    /// 이 창이 앱 전역 알림(업데이트 확인 결과)을 띄울 소유 창인지 (후속 T3).
    /// 온보딩 시트와 같은 이유·같은 규칙이다 — `AppEnvironment.globalAlertPresenterID` 참조.
    var isGlobalAlertPresenter: Bool {
        environment.isGlobalAlertPresenter(windowID)
    }

    /// 업데이트 확인 모델 (앱 전역 공유). 메뉴/알림이 이 경유점만 쓴다.
    var update: UpdateCheckModel { environment.update }

    // MARK: - 즐겨찾기 (2026-08-18 사용자 요청)

    /// 메뉴바 즐겨찾기 항목의 대상.
    ///
    /// - 선택이 없으면 **표시 중인 폴더** (Win10 탐색기의 "현재 폴더를 즐겨찾기에 고정"과 같은 감각)
    /// - 폴더 하나만 선택돼 있으면 그 폴더
    /// - 파일이 선택됐거나 다중 선택이면 `nil` → 메뉴 비활성 (폴더만 즐겨찾기가 된다)
    var favoriteTarget: URL? {
        if directory.selection.isEmpty { return navigation.currentURL }
        guard directory.selection.count == 1, let selected = directory.selection.first else { return nil }
        guard let item = directory.items.first(where: { PathKey.isSame($0.url, selected) }), item.isDirectory
        else { return nil }
        return item.url
    }

    /// Get Info 창의 대상 (후속 T5 / D2).
    ///
    /// **선택이 정확히 1개일 때만** 값이 있다 — `canRenameSelection`과 같은 규칙이다.
    /// 다중 선택에서 "첫 항목만" 보여주면 사용자가 고른 대상과 창의 대상이 달라 오해를 만든다.
    /// 합계 창("N items, 총 X GB")은 다른 화면이고 이번 범위가 아니다(followup-impl §4).
    ///
    /// **심볼릭 링크를 해석하지 않는다**(D3) — `InfoTarget` 주석 참조.
    var infoTarget: URL? {
        guard directory.selection.count == 1, let selected = directory.selection.first else { return nil }
        return directory.items.first(where: { PathKey.isSame($0.url, selected) })?.url ?? selected
    }

    /// 메뉴 항목을 등록/해제 중 **어느 쪽으로 띄울지** 결정하는 값 (둘 다 띄우지 않는다).
    var isFavoriteTargetRegistered: Bool {
        guard let target = favoriteTarget else { return false }
        return isFavorite(target)
    }

    func isFavorite(_ url: URL) -> Bool {
        settings.isFavorite(url)
    }

    /// 즐겨찾기 등록. 이미 있으면 아무 것도 하지 않는다(중복 등록 거부는 `AppSettings`가 판정).
    func addFavorite(_ url: URL) {
        guard settings.addFavorite(url) else { return }
        applyFavoriteSections()
    }

    /// 즐겨찾기 해제.
    ///
    /// **파일시스템은 건드리지 않는다** — 트리의 위험 대상 가드(`TreeModel.isProtectedNode`)가
    /// 막는 것은 rename/삭제이고, 이 액션은 목록에서만 빼는 별개 개념이라 그 가드와 무관하다.
    func removeFavorite(_ url: URL) {
        guard settings.removeFavorite(url) else { return }
        applyFavoriteSections()
    }

    /// 즐겨찾기 목록을 트리에 반영하는 **단일 지점**. 반영한 스냅샷을 기록해 두 경로
    /// (조작한 창의 직접 호출 · 전 창의 `.onChange` 동기화)가 같은 변경을 두 번 처리하지 않게 한다.
    private func applyFavoriteSections() {
        appliedFavoritePaths = settings.favoritePaths
        tree.rebuildSections()
        startReveal(navigation.currentURL)
    }

    func toggleFavorite(_ url: URL) {
        if isFavorite(url) {
            removeFavorite(url)
        } else {
            addFavorite(url)
        }
    }

    /// 메뉴바 항목이 쓰는 토글 (대상이 없으면 무시).
    func toggleFavoriteForCurrentTarget() {
        guard let target = favoriteTarget else { return }
        toggleFavorite(target)
    }

    // MARK: - 주소창 (T5)

    func beginAddressEditing() {
        isAddressEditing = true
    }

    func cancelAddressEditing() {
        isAddressEditing = false
        focusBroker.focus(.list)
    }

    /// 주소창 Enter 처리. 존재하지 않으면 셰이크 + 값 유지 (UI설계 §2.2).
    /// - Returns: 이동에 성공했으면 `true`
    @discardableResult
    func submitAddress(_ text: String) -> Bool {
        let expanded = (text as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            addressShakeTrigger += 1
            return false
        }

        let url = URL(fileURLWithPath: trimmed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            addressShakeTrigger += 1
            return false
        }

        if isDirectory.boolValue {
            isAddressEditing = false
            navigate(to: url, source: .breadcrumb)
        } else {
            // 파일이면 부모로 이동 후 해당 파일 선택 (UI설계 §2.2)
            isAddressEditing = false
            let parent = url.deletingLastPathComponent()
            navigate(to: parent, source: .breadcrumb)
            selectAfterLoad(NavigationModel.normalize(url))
        }
        return true
    }

    private func selectAfterLoad(_ url: URL) {
        // 로드 완료를 기다렸다가 선택을 반영한다(최대 2초).
        Task { [weak self] in
            for _ in 0..<40 {
                guard let self else { return }
                if self.directory.items.contains(where: { NavigationModel.normalize($0.url) == url }) {
                    if let match = self.directory.items.first(where: { NavigationModel.normalize($0.url) == url }) {
                        self.directory.selection = [match.url]
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - 클립보드 (M2 T3)

    /// 복사/잘라내기 대상 — 인자가 비었으면 현재 선택을 쓴다.
    /// 조작 대상은 **호출 시점 스냅샷**으로 고정한다 (m2-impl T0 — 진행 중 선택 변경 무시).
    func copy(_ urls: [URL]? = nil) {
        let targets = urls ?? directory.selectedItems.map(\.url)
        guard !targets.isEmpty else { return }
        clipboard.copy(targets)
    }

    func cut(_ urls: [URL]? = nil) {
        let targets = urls ?? directory.selectedItems.map(\.url)
        guard !targets.isEmpty else { return }
        clipboard.cut(targets)
    }

    var canPaste: Bool { clipboard.canPaste }

    // MARK: - Edit 메뉴 라우팅 (2026-08-18 D단계)

    /// Edit 메뉴의 Cut/Copy/Paste/Select All이 향할 곳.
    enum EditActionTarget: Equatable {
        /// 주소창·인라인 rename·시트의 텍스트 (responder chain으로 위임)
        case textField
        /// 우측 목록·좌측 트리의 파일 조작
        case files
    }

    /// responder chain에 텍스트 편집 대상이 서 있는지 (기본 구현은 first responder를 본다).
    ///
    /// 모델이 아는 `isTextEditing`(주소창·인라인 rename)만으로는 부족하다 — 충돌/온보딩 시트의
    /// 텍스트 필드처럼 **모델이 모르는 편집기**가 있다. 예전에는 표준 Edit 메뉴가 남아 있어
    /// 그쪽이 받아줬지만, `.pasteboard`를 교체한 뒤로는 이 판정이 유일한 안전망이다.
    /// 테스트가 responder chain 없이 분기를 고정할 수 있도록 주입 가능하게 둔다.
    @ObservationIgnored
    var isTextResponderActive: () -> Bool = { AppModel.firstResponderIsTextEditor() }

    static func firstResponderIsTextEditor() -> Bool {
        guard let responder = NSApp?.keyWindow?.firstResponder else { return false }
        // field editor는 `NSTextView`(= `NSText`)다. `NSTextField` 자체가 응답자인 경우도 받는다.
        return responder is NSText || responder is NSTextField
    }

    /// 지금 ⌘X/⌘C/⌘V/⌘A가 누구 것인지.
    var editActionTarget: EditActionTarget {
        isTextEditing || isTextResponderActive() ? .textField : .files
    }

    /// 텍스트 편집으로 넘길 때 쓰는 responder chain 위임 (테스트에서 교체 가능).
    @ObservationIgnored
    var forwardToTextResponder: (Selector) -> Void = { selector in
        NSApp?.sendAction(selector, to: nil, from: nil)
    }

    /// Edit 메뉴 "Cut" — 텍스트 편집 중이면 field editor에, 아니면 파일 잘라내기.
    ///
    /// **메뉴 항목을 `.disabled`로 내려서는 안 된다**: 그러면 ⌘X를 달고 있는 항목이 메뉴에
    /// 하나도 없게 되고, AppKit은 ⌘ 단축키를 responder chain보다 **메인 메뉴에서 먼저** 찾으므로
    /// 주소창·인라인 rename의 잘라내기가 통째로 죽는다. 게다가 메뉴 활성 상태는 SwiftUI가
    /// 뷰 갱신 시점에 계산하는 스냅샷이라 first responder 변화를 따라가지 못한다 —
    /// 그래서 **항상 활성으로 두고 동작만 분기**한다.
    func editCut() {
        switch editActionTarget {
        case .textField: forwardToTextResponder(#selector(NSText.cut(_:)))
        case .files: cut()
        }
    }

    func editCopy() {
        switch editActionTarget {
        case .textField: forwardToTextResponder(#selector(NSText.copy(_:)))
        case .files: copy()
        }
    }

    func editPaste() {
        switch editActionTarget {
        case .textField: forwardToTextResponder(#selector(NSText.paste(_:)))
        case .files: pasteIntoCurrentFolder()
        }
    }

    /// Edit 메뉴 "Select All" — `.pasteboard` 그룹을 교체하면 표준 항목이 함께 사라지므로 직접 되살린다.
    ///
    /// 목록/트리에는 `selectAll` 핸들러가 없고 `NSTableView`/`NSOutlineView`의 기본 구현에 기댄다.
    /// 두 경로 모두 셀렉터 문자열이 `selectAll:`로 같아서 위임 한 줄이면 된다.
    func editSelectAll() {
        forwardToTextResponder(#selector(NSText.selectAll(_:)))
    }

    /// Edit 메뉴 "Move Items Here"(⌥⌘V) — ⌥⌘V는 텍스트 단축키가 아니라 편집 중에는 무시한다.
    func editMoveItemsHere() {
        guard editActionTarget == .files else { return }
        moveClipboardItemsIntoCurrentFolder()
    }

    // MARK: - 붙여넣기 (M2 T4)

    /// 클립보드 항목을 `destination`으로 복사/이동한다.
    ///
    /// 대상 URL은 `currentURL` 암묵 참조가 아니라 **명시 인자**다 (m2-impl T0) —
    /// 트리 노드에서 연 컨텍스트 메뉴는 붙여넣기 대상이 현재 폴더와 다르다.
    func paste(into destination: URL) {
        let source = clipboard.pasteSource()
        guard !source.items.isEmpty else { return }
        performClipboardPaste(items: source.items, into: destination, isMove: source.operation == .cut)
    }

    /// Finder의 "Move Items Here"(⌥⌘V) — 클립보드 내용을 **무조건 이동**으로 붙여넣는다 (2026-08-18 D단계).
    ///
    /// Finder에는 파일 잘라내기가 없고 ⌘C 후 ⌥⌘V로 이동한다. UniFinder는 Win10식 ⌘X를
    /// 그대로 유지하면서 그 위에 이 진입점만 얹는다 — copy 클립보드든 외부 클립보드든 이동한다.
    ///
    /// **`paste(into:)`와 같은 경로를 쓴다**: `runOperation` 직렬화와 `applyOperationResult`라는
    /// 단일 경유점을 우회하면 조작 2건 동시 진행·트리 무효화 누락이 한꺼번에 생긴다(m3-impl T3/B9).
    func moveClipboardItems(into destination: URL) {
        let items = clipboard.moveSourceItems()
        guard !items.isEmpty else { return }
        performClipboardPaste(items: items, into: destination, isMove: true)
    }

    func moveClipboardItemsIntoCurrentFolder() {
        moveClipboardItems(into: navigation.currentURL)
    }

    /// 붙여넣기/이동의 공통 실행부. 대상과 연산이 정해진 뒤의 흐름은 완전히 같다.
    private func performClipboardPaste(items: [URL], into destination: URL, isMove: Bool) {
        let target = destination
        let kind: FileOperationKind = isMove ? .move : .copy
        let sourceParents = items.map { $0.deletingLastPathComponent() }

        runOperation(kind: kind) { [operations, conflictPresenter] sink in
            if isMove {
                return await operations.move(items: items, to: target, resolver: conflictPresenter, progress: sink)
            }
            return await operations.copy(items: items, to: target, resolver: conflictPresenter, progress: sink)
        } completion: { [weak self] result in
            guard let self else { return }
            // 이동은 1회 소비 후 클립보드를 비운다 (m2-impl T4).
            //
            // **단, 실제로 하나라도 이동에 성공했을 때만이다** (M2 백로그): 전부 실패했거나 충돌
            // 시트에서 취소했는데도 비우면 사용자는 잘라낸 항목을 잃고 처음부터 다시 잘라내야 한다.
            // `skipped`(같은 폴더 붙여넣기 등)도 소비로 치지 않는다 — 옮겨진 것이 하나도 없기 때문이다.
            //
            // 부분 성공(일부만 이동)은 **비운다**: 남은 항목을 다시 붙여넣어도 이미 이동된 원본은
            // 그 자리에 없어 `sourceMissing`만 반복되므로, 클립보드를 유지하는 편이 더 혼란스럽다.
            //
            // 판정 기준은 "잘라내기였는가"가 아니라 **"원본이 그 자리에서 사라졌는가"**다 (D단계).
            // ⌥⌘V는 copy 클립보드로도 이동을 수행하므로 그때도 같은 규칙으로 소비한다 —
            // 남겨두면 이어지는 ⌘V가 `sourceMissing`만 반복한다.
            if isMove, !result.produced.isEmpty {
                self.clipboard.clear()
            }
            self.applyOperationResult(
                result,
                kind: kind,
                affectedDirectories: [target] + (isMove ? sourceParents : []),
                selecting: result.produced
            )
        }
    }

    func pasteIntoCurrentFolder() {
        paste(into: navigation.currentURL)
    }

    // MARK: - 드래그앤드롭 (M3 T3)

    /// 드롭 실행의 **단일 진입점** (m3-impl T3/B9).
    ///
    /// 브릿지 Coordinator가 `FileOperations`를 직접 부르면 M2가 세운 서비스 가드는 통과하지만
    /// **`runOperation`의 직렬화와 `applyOperationResult`라는 단일 경유점을 통째로 우회한다** —
    /// 조작 2건 동시 진행(충돌 시트 중첩), 트리 무효화 누락, 폴더 소실 판정 누락이 한꺼번에 생긴다.
    /// 그래서 드롭은 `paste(into:)`와 **완전히 같은 경로**를 쓴다.
    ///
    /// 대상/원본 검증은 여기서 하지 않는다 — 권위는 `FileOperations`의 가드다(B10).
    /// UI 레벨 거부(커서 배지)는 브릿지의 `validateDrop`이 담당하는 보조 수단일 뿐이다.
    func drop(_ urls: [URL], into destination: URL, operation: FileOperationKind) {
        guard !urls.isEmpty else { return }
        // 드롭이 만들 수 있는 조작은 복사/이동 둘뿐이다.
        let kind: FileOperationKind = operation == .move ? .move : .copy
        let isMove = kind == .move
        let items = urls
        let target = destination
        let sourceParents = items.map { $0.deletingLastPathComponent() }

        runOperation(kind: kind) { [operations, conflictPresenter] sink in
            if isMove {
                return await operations.move(items: items, to: target, resolver: conflictPresenter, progress: sink)
            }
            return await operations.copy(items: items, to: target, resolver: conflictPresenter, progress: sink)
        } completion: { [weak self] result in
            guard let self else { return }
            self.applyOperationResult(
                result,
                kind: kind,
                affectedDirectories: [target] + (isMove ? sourceParents : []),
                selecting: result.produced
            )
        }
    }

    // MARK: - 휴지통 (M2 T2)

    /// 현재 선택 항목을 휴지통으로. 확인 다이얼로그 없음 (UI설계 §7.3).
    func trashSelection() {
        let targets = directory.selectedItems.map(\.url)
        guard !targets.isEmpty else { return }
        // 삭제 후 선택은 다음 항목으로 이동 (Win10 동작 — m2-impl T2)
        let nextSelection = selectionAfterRemoving(targets)
        trash(targets, in: navigation.currentURL, selectingAfterward: nextSelection)
    }

    func trash(_ urls: [URL], in parent: URL, selectingAfterward selection: [URL] = []) {
        guard !urls.isEmpty else { return }
        let items = urls
        runOperation(kind: .trash) { [operations] sink in
            await operations.trash(items: items, progress: sink)
        } completion: { [weak self] result in
            self?.applyOperationResult(
                result,
                kind: .trash,
                affectedDirectories: [parent],
                selecting: selection
            )
        }
    }

    /// 삭제 대상 제거 후 선택할 항목 — 사라진 첫 항목의 다음 항목, 없으면 마지막 항목.
    private func selectionAfterRemoving(_ removed: [URL]) -> [URL] {
        let removedKeys = PathKey.key(removed)
        let items = directory.items
        guard let firstIndex = items.firstIndex(where: { removedKeys.contains(PathKey.key($0.url)) })
        else { return [] }

        if let next = items[firstIndex...].first(where: { !removedKeys.contains(PathKey.key($0.url)) }) {
            return [next.url]
        }
        if let previous = items[..<firstIndex].last(where: { !removedKeys.contains(PathKey.key($0.url)) }) {
            return [previous.url]
        }
        return []
    }

    // MARK: - 이름 변경 (M2 T5)

    /// 인라인 편집을 시작하라고 브릿지에 지시한다. F2·메뉴·새 폴더가 공유하는 단일 경로.
    func requestRename(_ url: URL) {
        renameTokenCounter &+= 1
        renameRequest = RenameRequest(url: url, token: renameTokenCounter)
    }

    /// 현재 선택 항목의 이름 변경 (다중 선택이면 무동작 — UI설계 §6).
    func beginRenameSelection() {
        guard directory.selection.count == 1, let url = directory.selection.first else { return }
        requestRename(url)
    }

    var canRenameSelection: Bool { directory.selection.count == 1 }

    /// 커밋 직전 **동기** 검증 (UI설계 §7.2). 거부 사유를 돌려주면 편집이 유지된다.
    /// - Returns: 통과 시 `nil`, 거부 시 사용자 문구
    func validateRename(_ url: URL, to newName: String) -> String? {
        let parent = url.deletingLastPathComponent()
        let result = FileNameValidator.validate(
            newName,
            existingNames: Self.existingNames(in: parent),
            // 자기 자신 제외 — 대소문자만 바꾸는 rename이 중복으로 오판되지 않도록 (m2-impl T0)
            excluding: url.lastPathComponent
        )
        switch result {
        case .valid, .needsConfirmation:
            // 숨김화 확인 알림은 커밋 이후 `rename(_:to:)`에서 1회 띄운다.
            return nil
        case .invalid(let reason):
            return reason
        }
    }

    /// 같은 폴더 안의 기존 이름들. 숨김 항목까지 포함해야 중복 판정이 정확하므로 디스크에서 읽는다
    /// (`directory.items`는 숨김 설정에 따라 일부가 빠져 있다).
    private static func existingNames(in parent: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return Set(contents)
    }

    /// 검증을 통과한 이름으로 실제 rename을 수행한다.
    func rename(_ url: URL, to newName: String) {
        // 인라인 편집 종료 콜백 안에서 곧바로 실행하면 field editor 해제와 겹친다 —
        // 확인 알림/시트는 다음 런루프에서 띄운다.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.confirmHiddenNameIfNeeded(newName) else { return }
            self.performRename(url, to: newName)
        }
    }

    private func performRename(_ url: URL, to newName: String) {
        let parent = url.deletingLastPathComponent()
        let wasCurrentFolder = PathKey.isSame(url, navigation.currentURL)

        runOperation(kind: .rename) { [operations] _ in
            await operations.rename(item: url, to: newName)
        } completion: { [weak self] result in
            guard let self else { return }
            // 표시 중인 폴더 자체가 바뀌었으면 히스토리를 오염시키지 않고 경로만 교체한다 (m2-impl T1)
            if wasCurrentFolder, let renamed = result.produced.first {
                self.navigation.replaceCurrent(with: renamed)
                self.tree.invalidate(parent)
                self.directory.load(url: renamed)
                self.syncWatcher()
                self.report(result, kind: .rename)
                return
            }
            self.applyOperationResult(
                result,
                kind: .rename,
                affectedDirectories: [parent],
                selecting: result.produced
            )
        }
    }

    /// `.`으로 시작하는 이름은 숨김 항목이 되므로 1회 확인한다 (UI설계 §7.2).
    ///
    /// **앱-모달(`runModal`)이 아니라 윈도우 시트다** (M2 백로그): 이름 하나를 확인하려고 앱 전체를
    /// 블로킹할 이유가 없다. 시트 표시/응답 규약은 `ConflictSheetPresenter`가 세운 패턴
    /// (`beginSheetModal(for:)` + `withCheckedContinuation`)을 그대로 따른다.
    private func confirmHiddenNameIfNeeded(_ name: String) async -> Bool {
        guard Self.needsHiddenNameConfirmation(name, showHidden: settings.showHidden) else { return true }
        // 윈도우가 없거나 보이지 않으면(헤드리스/테스트) 확인 없이 진행한다.
        guard let window = focusBroker.window, window.isVisible else { return true }

        // 시트가 떠 있는 동안 도착한 외부 변경은 보류했다가 **닫힌 뒤** 1회 반영한다(B23).
        return await withExternalRefreshSuspended {
            await Self.presentHiddenNameSheet(name: name, in: window)
        }
    }

    /// 숨김화 확인이 필요한 이름인지 — 뷰 없이 검증할 수 있게 분리한 순수 판정.
    static func needsHiddenNameConfirmation(_ name: String, showHidden: Bool) -> Bool {
        name.hasPrefix(".") && !showHidden
    }

    /// - Returns: 사용자가 "사용"을 골랐으면 `true`. 취소하면 `false`(rename을 수행하지 않는다).
    private static func presentHiddenNameSheet(name: String, in window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Names that begin with a dot are hidden items."
        alert.informativeText = "If you use \"\(name)\", the item won't appear in the list unless Show Hidden Items is on."
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")

        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        return response == .alertFirstButtonReturn
    }

    // MARK: - 새 폴더 (M2 T6)

    /// `parent`에 새 폴더를 만들고 곧바로 인라인 이름 변경 모드로 진입한다.
    func createFolder(in parent: URL) {
        runOperation(kind: .createFolder) { [operations] _ in
            // 연속 생성 시 "새 폴더 2", "새 폴더 3" … (UI설계 §6 / m2-impl T6)
            await operations.createFolder(in: parent, uniqueBaseName: "untitled folder")
        } completion: { [weak self] result in
            guard let self else { return }
            self.applyOperationResult(
                result,
                kind: .createFolder,
                affectedDirectories: [parent],
                selecting: result.produced
            )
            // 현재 보고 있는 폴더에 만들었을 때만 인라인 rename으로 진입한다.
            if let created = result.produced.first, PathKey.isSame(parent, self.navigation.currentURL) {
                self.requestRename(created)
            }
        }
    }

    func createFolderInCurrentDirectory() {
        createFolder(in: navigation.currentURL)
    }

    // MARK: - Open With (후속 T4)

    /// 컨텍스트 메뉴 Open With — **이번 한 번만** 그 앱으로 연다(기본 앱은 바뀌지 않는다).
    ///
    /// 대상은 **선택 전체**다(reviewer minor #6 — Finder와 같은 규칙).
    /// 실행 실패는 상태바 메시지로 알린다(reviewer minor #7): `NSWorkspace.open`은 실패를
    /// completion handler로만 알리는데, 예전에는 그것을 버려서 앱이 지워졌거나 손상된 경우
    /// 사용자가 아무 반응 없는 화면만 보게 됐다.
    func openWith(_ fileURLs: [URL], application: URL) {
        guard !fileURLs.isEmpty else { return }
        openWithService.open(fileURLs, with: application) { [weak self] error in
            guard let error else { return }
            // completion handler는 AppKit이 임의 스레드에서 부른다 — 메시지는 메인 액터의 상태다.
            Task { @MainActor [weak self] in
                self?.showMessage(Self.openWithFailureMessage(
                    fileURLs: fileURLs,
                    application: application,
                    error: error
                ))
            }
        }
    }

    /// Open With > Other… — 앱을 직접 고른 뒤 연다. 취소하면 아무 일도 하지 않는다.
    func chooseApplicationAndOpen(_ fileURLs: [URL]) {
        guard !fileURLs.isEmpty, let application = applicationChooser() else { return }
        openWith(fileURLs, application: application)
    }

    /// 실행 실패 문구 (UI 문자열이라 영어). **뷰 없이 단언할 수 있도록** 정적 함수로 뺀다.
    nonisolated static func openWithFailureMessage(fileURLs: [URL], application: URL, error: Error) -> String {
        let applicationName = application.deletingPathExtension().lastPathComponent
        let subject = fileURLs.count == 1
            ? "\"\(fileURLs[0].lastPathComponent)\""
            : "\(fileURLs.count) items"
        return "Couldn't open \(subject) with \(applicationName): \(error.localizedDescription)"
    }

    /// `/Applications`에서 앱을 고르는 표준 패널. 실제 앱 경로에서만 쓰인다.
    static func presentApplicationOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Finder 위임 (M2 T7)

    /// "Finder에서 보기" — Finder 정보창을 여는 공개 API가 없어 항목 선택 표시로 대체한다
    /// (architect B9 → 승계: `ref-docs/specs/impl/unifinder-followup-impl.md` §1.2).
    ///
    /// **2026-08-19 정정**: B9의 전제("Finder 정보창을 여는 공개 API가 없다")는 지금도 참이지만,
    /// 결론은 확장됐다 — 자체 Get Info 창이 생겼으므로 `Cmd+I`는 그쪽이 갖고 이 항목은
    /// **단축키 없이** 남는다. 이 함수는 그대로 유지된다(Finder로 보내는 것은 여전히 유용한 조작이다).
    func revealInFinder(_ urls: [URL]? = nil) {
        let targets = urls ?? directory.selectedItems.map(\.url)
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(targets)
    }

    // MARK: - 조작 실행 공통

    /// 파일 조작 1건을 실행한다. 동시에 2건이 돌면 충돌 시트가 겹치므로 직렬화한다.
    private func runOperation(
        kind: FileOperationKind,
        _ body: @escaping @MainActor (OperationProgressSink) async -> OperationResult,
        completion: @escaping @MainActor (OperationResult) -> Void
    ) {
        guard operationTask == nil else {
            showMessage("Try again after the current file operation finishes.")
            return
        }
        isOperationInProgress = true
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.withProgress(kind: kind, body)
            self.operationTask = nil
            self.isOperationInProgress = false
            completion(result)
        }
    }

    /// 진행 중인 조작을 취소한다 (m3-impl T2/B20).
    ///
    /// 취소 의미론(UI설계 §7.4): **진행 중인 항목을 끝낸 뒤 중단**하고, 이미 처리된 항목은
    /// 그대로 둔다(롤백 없음 — undo는 Phase 2). 충돌 시트를 기다리는 중이라면
    /// `ConflictSheetPresenter`의 `withTaskCancellationHandler`가 continuation을 `.cancel`로
    /// 재개시키므로 조작이 행 상태로 남지 않는다.
    func cancelCurrentOperation() {
        guard let task = operationTask else { return }
        operationProgress.markCancelling()
        showMessage("Cancelling — items already processed will be kept.")
        task.cancel()
    }

    /// 진행 스트림을 **상태바 미니 표시 + 진행률 오버레이**에 연결한다 (UI설계 §5·§7.4).
    ///
    /// **여기가 스트림의 유일한 소비 지점이다** (m3-impl B17): `AsyncStream`은 단일 소비자라
    /// 두 번째 `for await`는 동작하지 않는다. T2는 새 consumer를 붙이는 대신 이 함수를 확장했다.
    private func withProgress(
        kind: FileOperationKind,
        _ body: @MainActor (OperationProgressSink) async -> OperationResult
    ) async -> OperationResult {
        let (stream, sink) = OperationProgressSink.makeStream()
        // 진행 틱이 한 번도 오지 않는 조작(rename/createFolder, 게이트에 걸린 대량 복사의 초반)도
        // "진행 중"임이 보여야 한다 — 시작 즉시 상태바 문구를 세운다.
        operationProgressText = kind.progressLabel
        operationProgress.begin(kind: kind)

        let consumer = Task { @MainActor [weak self] in
            for await progress in stream {
                guard let self else { return }
                self.operationProgress.update(progress)
                self.operationProgressText = progress.isFinished
                    ? nil
                    // B19 — 항목 수 기준만 표시한다(바이트·속도는 Phase 2).
                    : "\(kind.progressLabel) \(self.operationProgress.itemCountText)"
            }
            self?.operationProgressText = nil
        }
        let result = await body(sink)
        sink.finish()
        await consumer.value
        operationProgress.finish()
        operationProgressText = nil
        return result
    }

    /// 조작 결과를 화면에 반영한다: 트리 무효화 → 목록 재열거(+결과 선택) → 실패 요약.
    ///
    /// 모든 트리 조작이 `TreeModel.invalidate`를 경유하게 하는 단일 지점이다 (architect B8).
    private func applyOperationResult(
        _ result: OperationResult,
        kind: FileOperationKind,
        affectedDirectories: [URL],
        selecting: [URL]
    ) {
        var seen = Set<String>()
        for directory in affectedDirectories where seen.insert(PathKey.key(directory)).inserted {
            tree.invalidate(directory)
        }

        // 표시 중인 폴더 자체가 조작으로 사라진 경우(트리에서 현재 폴더를 삭제/이동)
        // 가장 가까운 상위로 내려간다 (설계서 §6과 동일 규칙).
        let current = navigation.currentURL
        let existing = Self.nearestExistingDirectory(current)
        if !PathKey.isSame(existing, current) {
            navigation.replaceCurrent(with: existing)
            showMessage("The folder no longer exists. Moved to the enclosing folder.")
            directory.load(url: existing)
            syncWatcher()
            startReveal(existing)
            report(result, kind: kind)
            return
        }

        let currentKey = PathKey.key(current)
        if affectedDirectories.contains(where: { PathKey.key($0) == currentKey }) {
            directory.reload(selecting: selecting)
        }
        report(result, kind: kind)
    }

    /// UI설계 §8 — 조작 실패는 알림(alert), 취소는 상태바 문구.
    private func report(_ result: OperationResult, kind: FileOperationKind) {
        guard let message = result.summaryMessage(for: kind) else { return }
        guard result.hasFailures else {
            showMessage(message)
            return
        }
        guard let window = focusBroker.window, window.isVisible else {
            showMessage(message)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some items couldn't be \(kind.completionVerb)."
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: - 상태 메시지

    func showMessage(_ message: String) {
        transientMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }

    // MARK: - 경로 유틸

    /// 존재하는 가장 가까운 상위 폴더 (설계서 §6 — 표시 중 폴더가 삭제된 경우).
    static func nearestExistingDirectory(_ url: URL) -> URL {
        var candidate = NavigationModel.normalize(url)
        let fileManager = FileManager.default

        for _ in 0..<128 {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            guard let parent = NavigationModel.parent(of: candidate) else { break }
            candidate = parent
        }
        return URL(fileURLWithPath: "/")
    }
}
