import Foundation
import Observation
import os

/// 우측 pane(현재 폴더 내용)의 상태 (설계서 §3.2 / §3.3).
///
/// - 이전 로드는 즉시 취소하고, 늦게 도착한 응답은 세대(generation) 검사로 폐기한다.
///   (취소를 존중하지 않는 로더 구현이 와도 "마지막 요청만 반영"이 성립하도록 이중 방어)
/// - 스피너는 200ms를 초과한 로드에만 표시한다(짧은 로드 깜빡임 방지).
/// - 정렬은 백그라운드에서 수행하고 결과만 MainActor에 반영한다(10만 항목 보호).
@Observable
@MainActor
final class DirectoryModel {

    // MARK: - 표시 상태

    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private(set) var error: DirectoryError?
    private(set) var currentURL: URL?

    /// 브릿지(NSTableView)가 `reloadData` 필요 여부를 판단하기 위한 카운터.
    ///
    /// **이 값이 바뀌면 브릿지는 "폴더가 통째로 바뀜"으로 해석한다** — 스크롤 최상단 이동 +
    /// 첫 행 강제 선택. 외부 변경 반영은 그러면 안 되므로 `contentsRevision`을 따로 둔다(m3-impl B5).
    private(set) var revision: Int = 0

    /// 외부 변경(FSEvents)으로 **목록 내용만** 갱신됐을 때 올라가는 카운터 (m3-impl T0/B5).
    ///
    /// `revision`과 분리한 이유: 브릿지가 `revision` 변화를 `.directoryChanged`로 보고
    /// `scrollRowToVisible(0)` + 첫 행 강제 선택까지 수행하기 때문이다. 외부 변경마다 그러면
    /// 화면이 깜빡이고 스크롤이 튄다(T0 수용 기준과 정면 충돌).
    ///
    /// `items.count` 비교(`.itemsChanged`)로 대체할 수 없다 — 1개 추가 + 1개 삭제면 개수가 같아
    /// 갱신이 통째로 누락된다.
    private(set) var contentsRevision: Int = 0

    /// 선택된 항목의 URL 집합. 목록 브릿지와 양방향으로 동기화된다.
    var selection: Set<URL> = []

    private(set) var sortDescriptor: FileSortDescriptor

    /// 숨김 항목 표시 여부. 변경 시 현재 폴더를 다시 열거한다.
    private(set) var showHidden: Bool

    // MARK: - 의존성

    private let loader: any DirectoryListing

    // MARK: - 로드 상태

    private var loadTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private var generation: Int = 0

    /// 외부 변경 반영용 재열거 (m3-impl T0). `loadTask`와 분리해야 `load()`의 취소 규칙
    /// ("마지막 요청만 반영")을 건드리지 않고 독립적으로 취소/교체할 수 있다.
    private var contentsTask: Task<Void, Never>?

    /// 다음 로드가 끝나면 선택할 항목들의 경로 키 (m2-impl T4 / architect B5).
    ///
    /// `load()`는 시작 시 `selection`을 비우므로 "붙여넣은 항목을 선택"은 호출 시점에 표현할
    /// 수 없다. `AppModel.selectAfterLoad`의 폴링(최대 2초) 방식을 파괴적 작업 경로에 재사용하면
    /// 조작 결과가 늦게/영영 반영되지 않을 수 있어, 로드 파이프라인 안에서 확정적으로 처리한다.
    ///
    /// URL 값이 아니라 `PathKey` 문자열로 들고 있는 이유: `DirectoryLoader.makeItem`이 만드는
    /// 폴더 URL에는 후행 슬래시가 붙지만 조작 결과 URL에는 붙지 않아 값 비교가 어긋난다.
    private var pendingSelectionKeys: Set<String> = []

    /// 스피너 표시 임계 (설계서 §3.3)
    static let spinnerDelay: Duration = .milliseconds(200)

    init(
        loader: any DirectoryListing = DirectoryLoader.shared,
        sortDescriptor: FileSortDescriptor = .default,
        showHidden: Bool = false
    ) {
        self.loader = loader
        self.sortDescriptor = sortDescriptor
        self.showHidden = showHidden
    }

    // MARK: - 파생 상태

    var itemCount: Int { items.count }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.url) }
    }

    // MARK: - 로드

    /// 폴더를 (재)열거한다. 진행 중이던 로드는 즉시 취소된다.
    /// - Parameter preservingSelection: 새로고침처럼 기존 선택을 URL 기준으로 되살릴지 여부.
    func load(url: URL, preservingSelection: Bool = false) {
        loadTask?.cancel()
        spinnerTask?.cancel()
        // 이전 폴더에 대한 외부 갱신이 새 폴더 목록에 끼어들지 않게 한다 (m3-impl T0).
        contentsTask?.cancel()

        generation &+= 1
        let requestGeneration = generation

        let previousSelection = preservingSelection ? selection : []
        let pendingKeys = pendingSelectionKeys
        pendingSelectionKeys = []

        currentURL = url
        error = nil
        isLoading = false
        // UI설계 §4.2 — 이전 폴더 내용 잔상 금지
        items = []
        selection = []
        revision &+= 1

        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.spinnerDelay)
            guard !Task.isCancelled, let self else { return }
            guard self.generation == requestGeneration else { return }
            self.isLoading = true
        }

        let includeHidden = showHidden
        let loader = self.loader

        loadTask = Task { [weak self] in
            let signpostState = PerfLog.beginDirectoryLoad(url)
            do {
                let raw = try await loader.list(at: url, showHidden: includeHidden)
                try Task.checkCancellation()

                guard let self, self.generation == requestGeneration else {
                    PerfLog.cancelDirectoryLoad(signpostState, url: url)
                    return
                }
                // 로딩 중 헤더 클릭으로 정렬이 바뀌었을 수 있다. 시작 시점 값이 아니라
                // "정렬 직전"의 최신 descriptor를 읽어야 변경이 유실되지 않는다.
                // (items가 비어 있는 동안에는 resortCurrentItems가 즉시 반환하므로
                //  로드 결과를 반영하는 이 지점이 유일한 반영 기회다)
                let descriptor = self.sortDescriptor

                let sorted = await Self.sortInBackground(raw, by: descriptor)
                try Task.checkCancellation()

                guard self.generation == requestGeneration else { return }
                self.spinnerTask?.cancel()
                self.items = sorted
                if !previousSelection.isEmpty {
                    let available = Set(sorted.map(\.url))
                    self.selection = previousSelection.intersection(available)
                }
                if !pendingKeys.isEmpty {
                    // 조작 결과 항목 선택 — 경로 키로 비교한다(후행 슬래시 표기 차이 흡수).
                    let matched = sorted.filter { pendingKeys.contains(PathKey.key($0.url)) }.map(\.url)
                    if !matched.isEmpty {
                        self.selection = Set(matched)
                    }
                }
                self.error = nil
                self.isLoading = false
                self.revision &+= 1
                PerfLog.endDirectoryLoad(signpostState, url: url, itemCount: sorted.count)

                // 정렬하는 동안 또 바뀌었다면(이중 창) 현재 목록만 다시 정렬한다.
                if self.sortDescriptor != descriptor {
                    self.resortCurrentItems()
                }
            } catch is CancellationError {
                // 취소된 요청은 어떤 상태도 건드리지 않는다.
                PerfLog.cancelDirectoryLoad(signpostState, url: url)
            } catch {
                guard let self, self.generation == requestGeneration else {
                    PerfLog.cancelDirectoryLoad(signpostState, url: url)
                    return
                }
                self.spinnerTask?.cancel()
                self.items = []
                self.selection = []
                self.error = DirectoryError.map(error)
                self.isLoading = false
                self.revision &+= 1
                PerfLog.endDirectoryLoad(signpostState, url: url, itemCount: 0)
            }
        }
    }

    /// 현재 폴더 재열거. 선택은 URL 기준으로 유지된다(사라진 항목은 자동 해제).
    func reload() {
        guard let currentURL else { return }
        load(url: currentURL, preservingSelection: true)
    }

    // MARK: - 외부 변경 반영 (m3-impl T0 / B5·B6)

    /// **in-place 갱신** — 현재 폴더를 다시 열거해 목록만 교체한다 (FSEvents 전용 경로).
    ///
    /// `load()`/`reload()`와 다른 점이 T0 수용 기준 그 자체다:
    /// - `items`를 비우지 않는다 → 빈 화면 깜빡임 없음
    /// - `selection`을 비우지 않는다 → **사라진 항목만** 해제, 나머지 선택 유지
    /// - `revision`을 올리지 않는다 → 브릿지가 스크롤을 최상단으로 되돌리지 않음
    /// - **`pendingSelectionKeys`를 소비하지 않는다** (B6) → 붙여넣기 직후 그 조작이 유발한
    ///   FSEvent가 "결과 항목 선택"을 먹어치우지 않는다
    /// - 실패(권한/삭제)해도 현재 화면을 지우지 않는다 → 폴더 소실 판정은 watcher/`AppModel` 몫(B7)
    func refreshContents() {
        guard let currentURL else { return }
        contentsTask?.cancel()

        // 진행 중인 `load`가 있으면 그 세대와 함께 폐기된다(늦게 도착한 외부 갱신이
        // 새 폴더의 목록을 덮어쓰지 않도록 하는 이중 방어 — `load`와 같은 규칙).
        let requestGeneration = generation
        let includeHidden = showHidden
        let loader = self.loader
        let url = currentURL

        contentsTask = Task { [weak self] in
            do {
                let raw = try await loader.list(at: url, showHidden: includeHidden)
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration else { return }

                let sorted = await Self.sortInBackground(raw, by: self.sortDescriptor)
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { return }
                self.applyExternalUpdate(sorted)
            } catch {
                // 외부 변경 반영 실패는 조용히 무시한다 — 현재 목록을 지우거나 에러 화면으로
                // 바꾸면 "터미널에서 파일 하나 지웠더니 화면이 통째로 날아갔다"가 된다.
            }
        }
    }

    /// 열거 결과를 목록에 in-place로 반영한다. 내용이 같으면 아무 신호도 내지 않는다(멱등 — B7).
    ///
    /// 자기 조작이 유발한 FSEvent가 `applyOperationResult`의 갱신과 겹쳐도 여기서 흡수되므로
    /// 화면에는 중복 갱신이 보이지 않는다.
    func applyExternalUpdate(_ newItems: [FileItem]) {
        guard newItems != items else {
            // 내용이 같아도 열거에 성공했다는 사실 자체는 반영한다(권한 복구 등).
            if error != nil {
                error = nil
                contentsRevision &+= 1
            }
            return
        }

        // 선택 유지 규칙: 새 목록에 **여전히 존재하는** 항목만 남긴다.
        // URL 값이 아니라 `PathKey`로 대조하는 이유는 폴더 URL의 후행 슬래시 표기 차이다.
        var urlByKey: [String: URL] = [:]
        urlByKey.reserveCapacity(newItems.count)
        for item in newItems where urlByKey[PathKey.key(item.url)] == nil {
            urlByKey[PathKey.key(item.url)] = item.url
        }
        let survivingSelection = Set(selection.compactMap { urlByKey[PathKey.key($0)] })

        items = newItems
        if survivingSelection != selection {
            selection = survivingSelection
        }
        error = nil
        contentsRevision &+= 1
    }

    /// 파일 조작 후 재열거 + **결과 항목 선택** (m2-impl T4 / architect B5).
    ///
    /// 붙여넣기·이름 변경·새 폴더 생성 직후 그 항목이 선택된 채로 보여야 한다.
    /// FSEvents는 M3이므로 M2에서는 조작 경로가 이 API를 명시적으로 호출한다.
    /// - Parameter urls: 선택할 항목들. 재열거 결과에 없으면 조용히 무시된다.
    func reload(selecting urls: some Sequence<URL>) {
        guard let currentURL else { return }
        pendingSelectionKeys = PathKey.key(urls)
        load(url: currentURL, preservingSelection: false)
    }

    // MARK: - 정렬 / 숨김

    /// 헤더 클릭 등으로 정렬만 바뀐 경우 — 재열거 없이 현재 목록만 다시 정렬한다.
    func applySort(_ descriptor: FileSortDescriptor) {
        guard descriptor != sortDescriptor else { return }
        sortDescriptor = descriptor
        resortCurrentItems()
    }

    func toggleSort(for key: SortKey) {
        applySort(sortDescriptor.toggled(for: key))
    }

    private func resortCurrentItems() {
        guard !items.isEmpty else {
            revision &+= 1
            return
        }
        let snapshot = items
        let descriptor = sortDescriptor
        let requestGeneration = generation

        Task { [weak self] in
            let sorted = await Self.sortInBackground(snapshot, by: descriptor)
            guard let self, self.generation == requestGeneration else { return }
            self.items = sorted
            self.revision &+= 1
        }
    }

    func setShowHidden(_ newValue: Bool) {
        guard newValue != showHidden else { return }
        showHidden = newValue
        reload()
    }

    // MARK: - 백그라운드 정렬

    /// 10만 항목 정렬이 메인 스레드를 막지 않도록 detached 태스크에서 수행한다.
    private static func sortInBackground(
        _ items: [FileItem],
        by descriptor: FileSortDescriptor
    ) async -> [FileItem] {
        // 항목 수가 적으면 태스크 전환 비용이 더 크다.
        if items.count < 2_000 {
            return items.sorted(by: descriptor)
        }
        return await Task.detached(priority: .userInitiated) {
            items.sorted(by: descriptor)
        }.value
    }
}
