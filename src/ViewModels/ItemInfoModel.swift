import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Get Info 창 1개분의 상태 (후속 T5·T6 / UI설계 §7.6).
///
/// **`AppModel.resolveTarget(of:)`을 쓰지 않는다** (D3 / 설계서 §6 규약):
/// `Open`은 **의도**를 다루므로 심볼릭 링크를 해석해 타겟으로 가지만, Get Info는 **관찰**을 다룬다.
/// 링크 파일의 정보를 물은 사용자에게 타겟의 크기·날짜를 답하면 그것은 다른 질문에 대한 답이다.
/// 해석된 경로는 `Original:` 행에 병기한다. 이 규약은 `InfoTargetSymlinkTests`가 봉인한다.
///
/// 파일 IO는 전부 메인 액터 **밖**에서 한다(§5 성능 요구: 창 열기 < 100ms, 메인 블로킹 0).
@Observable
@MainActor
final class ItemInfoModel {

    /// 읽어 들인 메타데이터 (표시 전용 값 묶음).
    struct Attributes: Equatable, Sendable {
        var name: String
        /// "종류" — `UTType.localizedDescription` 기반.
        var kind: String
        /// UTI 문자열(`com.adobe.pdf`). 알 수 없으면 `nil`.
        var typeIdentifier: String?
        var isDirectory: Bool
        var isSymbolicLink: Bool
        /// 심볼릭 링크가 가리키는 **해석된 경로** — `Original:` 행.
        var symbolicLinkDestination: String?
        /// 상위 폴더 경로 — `Where:` 행.
        var location: String
        /// 파일의 논리 크기. **폴더는 항상 `nil`**이다(설계서 §3.2 불변식 1) — 폴더 크기는
        /// 아래 `folderSize`가 비동기로 채운다.
        var byteSize: Int64?
        /// 디스크에 실제 할당된 크기 — **파일에만** 채운다("Size on disk" 행).
        ///
        /// 이 값은 `read()`가 다른 속성과 **함께 prefetch**하는 것이라 추가 비용이 없고,
        /// Finder의 Get Info도 같은 항목을 보여준다. 설계서 §3.2 불변식 3(논리 크기만 더한다)은
        /// **폴더 크기 계산기**(`DirectorySizeCalculator`)에 대한 규칙이지 이 행에 대한 규칙이 아니다 —
        /// 폴더에서는 애초에 `nil`이므로 두 값이 한 화면에 동시에 뜨는 일도 없다.
        var allocatedSize: Int64?
        var createdAt: Date?
        var modifiedAt: Date?
        var accessedAt: Date?
        var owner: String?
        var group: String?
        /// `rw-r--r--` 형식.
        var permissions: String?
        var isLocked: Bool
        var tags: [String]
    }

    /// 폴더 크기 계산 상태 (T6).
    enum FolderSize: Equatable {
        /// 대상이 폴더가 아니다 — 크기는 `Attributes.byteSize`에 이미 들어 있다.
        case notApplicable
        /// 계산 중. `partial`은 지금까지의 부분 합계(500ms마다 갱신).
        case calculating(bytes: Int64, itemCount: Int)
        case done(bytes: Int64, itemCount: Int, isIncomplete: Bool)
        /// 폴더를 열 수조차 없었다.
        case failed
    }

    /// 창 전체의 로드 상태.
    enum LoadState: Equatable {
        case loading
        case loaded
        /// 표 대신 한 줄 안내를 띄운다(UI설계 §7.6).
        case failed(message: String)
    }

    let target: InfoTarget

    private(set) var state: LoadState = .loading
    private(set) var attributes: Attributes?
    private(set) var folderSize: FolderSize = .notApplicable

    /// Get Info 창의 "Open with:" 팝업 후보 (T7). 폴더에서는 비어 있다.
    private(set) var applications: [ApplicationOption] = []
    /// 팝업에서 지금 선택된 앱.
    private(set) var selectedApplication: URL?

    /// `Change All…`이 적용될 파일 종류.
    ///
    /// **접근할 때마다 조회하지 않고 `load()` 때 한 번만 읽는다**(reviewer minor #4).
    /// 예전에는 computed property가 매번 `contentTypeProvider`(= `URL.resourceValues`, 즉 stat)를
    /// 불렀는데, 이 값을 읽는 `changeAllConfirmationMessage`는 **뷰 `body`에서 호출된다** —
    /// 렌더 한 번마다 디스크 stat 한 번이라는 뜻이고, 느린/끊긴 볼륨에서는 그 stat이
    /// 메인 액터를 잡는다(§5 "메인 블로킹 0"에 정면으로 어긋난다).
    /// 파일의 종류는 창이 떠 있는 동안 바뀌지 않는 값이라 한 번 읽어 두면 충분하다.
    private(set) var changeAllContentType: UTType?
    /// 기본 앱 변경 실패 안내 (nil이면 없음).
    var applicationErrorMessage: String?

    /// `[Change All…]` 확인 alert 표시 여부 (UI설계 §7.8).
    var isChangeAllConfirmationPresented = false

    @ObservationIgnored
    private let openWithService: OpenWithService

    @ObservationIgnored
    private let calculator: DirectorySizeCalculator

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    @ObservationIgnored
    private var sizeTask: Task<Void, Never>?

    /// "Open with:" 선택의 세대 번호 — 연타로 겹친 Task 중 **마지막 것만** 상태를 되돌릴 수 있다.
    @ObservationIgnored
    private var applicationSelectionGeneration = 0

    /// 마지막으로 **확정된**(로드 직후 또는 변경 성공) 선택 상태 — 실패 시 되돌아갈 곳이다.
    /// 화면에 보이는 `selectedApplication`/`applications`는 아직 확정되지 않았을 수 있다.
    @ObservationIgnored
    private var confirmedSelection: URL?

    @ObservationIgnored
    private var confirmedApplications: [ApplicationOption] = []

    init(
        target: InfoTarget,
        openWithService: OpenWithService = OpenWithService(),
        calculator: DirectorySizeCalculator = DirectorySizeCalculator()
    ) {
        self.target = target
        self.openWithService = openWithService
        self.calculator = calculator
    }

    deinit {
        loadTask?.cancel()
        sizeTask?.cancel()
    }

    // MARK: - 수명주기

    /// 창이 뜰 때 1회. 메타데이터를 백그라운드에서 읽고, 폴더면 크기 계산까지 이어 붙인다.
    func load() {
        loadTask?.cancel()
        let url = target.url
        loadTask = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                ItemInfoModel.read(url)
            }.value
            guard let self, !Task.isCancelled else { return }
            await self.apply(outcome)
        }
    }

    /// 창이 닫힐 때 — 진행 중인 폴더 크기 계산을 **즉시** 멈춘다(§5 성능 요구).
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        sizeTask?.cancel()
        sizeTask = nil
    }

    /// 테스트가 완료를 기다리는 지점.
    func waitForLoad() async {
        await loadTask?.value
    }

    func waitForFolderSize() async {
        await sizeTask?.value
    }

    /// `async`인 이유: 파일이면 "Open with:" 후보 조회(LaunchServices)가 이어지는데 그 조회가
    /// 메인 액터 밖에서 도는 비동기 작업이다. `load()`가 이 함수를 `await`하므로
    /// `waitForLoad()` 하나로 **메타데이터 + 후보 목록**이 모두 확정된다(테스트 대기 지점이 둘로 갈리지 않는다).
    private func apply(_ outcome: Result<Attributes, ItemInfoError>) async {
        switch outcome {
        case let .success(attributes):
            self.attributes = attributes
            state = .loaded
            // 폴더에는 "Open with:"를 띄우지 않는다(UI설계 §7.6) — 폴더의 기본 앱 변경은 범위 밖이다.
            if attributes.isDirectory {
                folderSize = .calculating(bytes: 0, itemCount: 0)
                startFolderSizeCalculation()
            } else {
                folderSize = .notApplicable
                await loadApplications()
            }

        case let .failure(error):
            state = .failed(message: error.message)
            attributes = nil
            folderSize = .notApplicable
        }
    }

    // MARK: - 폴더 크기 (T6)

    private func startFolderSizeCalculation() {
        sizeTask?.cancel()
        let url = target.url
        let calculator = self.calculator
        // 진행 콜백은 **Task 밖에서 한 번만** 만든다. Task 본문 안에서 다시 `[weak self]`를 잡으면
        // 동시 실행 코드가 캡처된 `self` 변수를 읽게 되어 Swift 6에서는 에러다(지금은 경고).
        let applyProgress: @Sendable (DirectorySizeCalculator.Progress) async -> Void = { [weak self] progress in
            // 약한 참조를 **지역 상수로 먼저 꺼낸다**. `MainActor.run` 안에서 `self`를 직접 쓰면
            // 캡처된 옵셔널 변수를 동시 실행 코드가 읽는 형태가 되어 경고(Swift 6에서는 에러)다.
            // `ItemInfoModel`은 `@MainActor` 클래스라 참조 자체는 `Sendable`이다.
            guard let model = self else { return }
            // 부분 합계는 메인 액터로 되돌려 표시한다(500ms 스로틀은 계산기가 건다).
            await MainActor.run {
                guard case .calculating = model.folderSize else { return }
                model.folderSize = .calculating(bytes: progress.bytes, itemCount: progress.itemCount)
            }
        }

        sizeTask = Task { @MainActor [weak self] in
            do {
                let final = try await calculator.calculate(at: url, onProgress: applyProgress)
                guard let self, !Task.isCancelled else { return }
                self.folderSize = .done(
                    bytes: final.bytes,
                    itemCount: final.itemCount,
                    isIncomplete: final.isIncomplete
                )
            } catch is CancellationError {
                // 창이 닫혔거나 대상이 바뀐 것이다 — 상태를 건드리지 않고 조용히 끝낸다.
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.folderSize = .failed
            }
        }
    }

    // MARK: - Open With / 기본 앱 (T7)

    /// "Open with:" 후보를 채운다.
    ///
    /// **LaunchServices 조회는 메인 액터 밖에서 한다** (reviewer major #5 / 타입 주석의 §5 성능 요구).
    /// `NSWorkspace.urlsForApplications(toOpen:)`와 `urlForApplication(toOpen:)`은 동기 호출이지만
    /// 내부적으로 LaunchServices 데이터베이스에 물어보는 IPC라, 데이터베이스가 재빌드 중이거나
    /// 후보 앱이 느린 볼륨에 있으면 수백 ms 이상 걸린다. 메인 액터에서 부르면 그동안 Get Info 창은
    /// 물론 앱 전체가 멈춘다 — `read()`를 백그라운드로 뺀 이유와 정확히 같다.
    ///
    /// 반영은 메인 액터에서, 두 값을 **연달아** 대입한다(중간 상태가 화면에 보이지 않는다).
    private func loadApplications() async {
        let service = openWithService
        let url = target.url
        // `Change All…`의 대상 UTType도 **여기서 함께** 읽는다(reviewer minor #4) — 이것도
        // 디스크를 건드리는 조회라 뷰 렌더 경로에 두면 안 된다. 같은 detached 작업에 얹으면
        // 왕복이 늘지 않는다.
        let loaded = await Task.detached(priority: .userInitiated) {
            (options: service.applications(for: url), contentType: service.contentType(of: url))
        }.value
        // 창이 닫혔거나 대상이 바뀌었으면 조용히 끝낸다(늦게 도착한 결과가 화면을 되살리지 않게).
        guard !Task.isCancelled else { return }
        applications = loaded.options
        selectedApplication = loaded.options.first(where: \.isDefault)?.url ?? loaded.options.first?.url
        changeAllContentType = loaded.contentType
        // 방금 읽은 값이 곧 "확정된 상태"다 — 실패한 변경은 여기로 되돌아온다.
        confirmedApplications = applications
        confirmedSelection = selectedApplication
    }

    /// 팝업에서 앱을 골랐다 — **이 파일 하나**의 기본 앱을 바꾼다(확인 없음, UI설계 §7.8).
    /// 실패하면 사유를 띄우고 선택을 **이전 값으로 되돌린다**.
    ///
    /// **연타 안전**(reviewer minor #5): 팝업을 빠르게 두 번 고르면 Task가 둘 겹친다.
    /// 예전에는 두 번째 호출이 롤백 값으로 **첫 번째의 미확정 상태**(성공/실패가 아직 정해지지 않은
    /// 낙관적 값)를 붙잡았다 — 두 번째가 실패하면 화면이 "확정된 적 없는 앱"으로 되돌아가,
    /// 실제 기본 앱과 어긋난 표시가 남았다. 규칙 둘로 막는다:
    /// 1. **세대 카운터** — 가장 마지막 선택의 결과만 상태를 건드린다(늦게 끝난 이전 Task는 무시).
    /// 2. **확정 상태로만 롤백** — 되돌아갈 곳은 마지막으로 *성공한* 상태(또는 로드 직후 상태)다.
    ///
    /// 롤백은 `selectedApplication`뿐 아니라 `applications`의 `isDefault` 플래그까지 함께
    /// 되돌린다 — 팝업 항목의 `(default)` 표기가 그 플래그에서 나오므로, 하나만 되돌리면
    /// "선택은 Preview인데 표기는 Acrobat이 default"라는 모순된 화면이 남는다.
    func selectApplication(_ applicationURL: URL) {
        guard selectedApplication != applicationURL else { return }

        applicationSelectionGeneration &+= 1
        let generation = applicationSelectionGeneration

        // 낙관적 반영 — 성공이 압도적으로 흔한 경로라 팝업이 즉시 응답해야 한다.
        selectedApplication = applicationURL
        applications = Self.applications(applications, markingDefault: applicationURL)
        applicationErrorMessage = nil

        let service = openWithService
        let fileURL = target.url
        Task { @MainActor [weak self] in
            do {
                try await service.setDefaultApplication(applicationURL, forFileAt: fileURL)
                guard let self, generation == self.applicationSelectionGeneration else { return }
                // 성공했다 — 지금 화면이 곧 확정 상태다(다음 실패는 여기로 되돌아온다).
                self.confirmedSelection = self.selectedApplication
                self.confirmedApplications = self.applications
            } catch {
                guard let self, generation == self.applicationSelectionGeneration else { return }
                self.selectedApplication = self.confirmedSelection
                self.applications = self.confirmedApplications
                self.applicationErrorMessage = "Couldn't change the default application: \(error.localizedDescription)"
            }
        }
    }

    /// `isDefault` 플래그만 갈아 끼운 후보 목록(순서는 그대로 둔다 — 고른 항목이 갑자기
    /// 맨 위로 튀어 오르면 다음 선택에서 사용자가 다른 항목을 누르게 된다).
    nonisolated static func applications(
        _ options: [ApplicationOption],
        markingDefault applicationURL: URL
    ) -> [ApplicationOption] {
        options.map {
            ApplicationOption(url: $0.url, name: $0.name, isDefault: $0.url == applicationURL)
        }
    }

    /// `[Change All…]` — 확인 alert를 띄우기만 한다. 실제 변경은 사용자가 확인한 뒤에만 일어난다.
    func requestChangeAll() {
        guard selectedApplication != nil, changeAllContentType != nil else { return }
        isChangeAllConfirmationPresented = true
    }

    /// 확인 alert의 [Change All] — 여기서만 시스템 전역 설정이 바뀐다.
    func confirmChangeAll() {
        isChangeAllConfirmationPresented = false
        guard let applicationURL = selectedApplication, let contentType = changeAllContentType else { return }

        let service = openWithService
        Task { @MainActor [weak self] in
            do {
                try await service.setDefaultApplication(applicationURL, forContentType: contentType)
            } catch {
                self?.applicationErrorMessage = "Couldn't change the default application: \(error.localizedDescription)"
            }
        }
    }

    /// 확인 alert의 [Cancel] — **어떤 API도 부르지 않는다**(회귀 테스트로 고정).
    func cancelChangeAll() {
        isChangeAllConfirmationPresented = false
    }

    /// 확인 alert 문구 (UI설계 §7.8).
    var changeAllConfirmationMessage: String {
        let application = selectedApplication?.deletingPathExtension().lastPathComponent ?? "the selected application"
        let kind = attributes?.kind ?? changeAllContentType?.localizedDescription ?? "this kind"
        let name = attributes?.name ?? target.displayName
        return """
        Change all documents of type "\(kind)" to open with \(application)?

        This applies to every \(kind) on this Mac, not just "\(name)".
        """
    }

    // MARK: - 메타데이터 읽기 (메인 액터 밖)

    enum ItemInfoError: Error, Equatable {
        case notFound
        case permissionDenied
        case unreadable(String)

        /// UI설계 §7.6 — 표 대신 띄우는 한 줄 안내 (UI 문자열이라 영어).
        var message: String {
            switch self {
            case .notFound: return "This item is no longer available."
            case .permissionDenied: return "You don't have permission to read this item."
            case let .unreadable(detail): return "This item couldn't be read: \(detail)"
            }
        }
    }

    /// 파일시스템에서 표시할 값을 읽는다. **`nonisolated`**라 백그라운드에서 그대로 돈다.
    ///
    /// `URL.resourceValues`와 `FileManager.attributesOfItem`은 둘 다 **링크를 따라가지 않는다**
    /// (lstat 의미론) — D3가 요구하는 "링크 자체의 메타데이터"가 추가 조치 없이 그대로 나온다.
    nonisolated static func read(_ url: URL) -> Result<Attributes, ItemInfoError> {
        let keys: Set<URLResourceKey> = [
            .nameKey, .localizedNameKey, .contentTypeKey, .localizedTypeDescriptionKey,
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .creationDateKey, .contentModificationDateKey, .contentAccessDateKey,
            .isUserImmutableKey, .tagNamesKey,
        ]

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch let error as CocoaError {
            switch error.code {
            case .fileReadNoSuchFile, .fileNoSuchFile:
                return .failure(.notFound)
            case .fileReadNoPermission:
                return .failure(.permissionDenied)
            default:
                return .failure(.unreadable(error.localizedDescription))
            }
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }

        let isDirectory = values.isDirectory ?? false
        let isSymlink = values.isSymbolicLink ?? false
        let posix = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]

        var attributes = Attributes(
            name: values.localizedName ?? values.name ?? url.lastPathComponent,
            kind: values.localizedTypeDescription ?? values.contentType?.localizedDescription ?? "Unknown",
            typeIdentifier: values.contentType?.identifier,
            isDirectory: isDirectory,
            isSymbolicLink: isSymlink,
            symbolicLinkDestination: isSymlink ? resolvedDestination(of: url) : nil,
            location: url.deletingLastPathComponent().path,
            // **폴더는 항상 nil** — 설계서 §3.2 불변식 1. 폴더 크기는 계산기가 따로 채운다.
            byteSize: isDirectory ? nil : values.fileSize.map(Int64.init),
            allocatedSize: isDirectory ? nil : values.totalFileAllocatedSize.map(Int64.init),
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate,
            accessedAt: values.contentAccessDate,
            owner: posix[.ownerAccountName] as? String,
            group: posix[.groupOwnerAccountName] as? String,
            permissions: (posix[.posixPermissions] as? NSNumber).map { permissionString(from: $0.uint16Value) },
            isLocked: values.isUserImmutable ?? ((posix[.immutable] as? NSNumber)?.boolValue ?? false),
            tags: values.tagNames ?? []
        )

        // 이름이 빈 경우(루트 등)에는 경로로 대체한다.
        if attributes.name.isEmpty { attributes.name = url.path }
        return .success(attributes)
    }

    /// 심볼릭 링크의 대상 경로 — 상대 경로면 링크가 있는 폴더 기준으로 해석한다.
    nonisolated static func resolvedDestination(of url: URL) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        if destination.hasPrefix("/") { return URL(fileURLWithPath: destination).standardizedFileURL.path }
        return url.deletingLastPathComponent()
            .appendingPathComponent(destination)
            .standardizedFileURL
            .path
    }

    /// `rw-r--r--` 형식으로 옮긴다(맨 앞 파일 종류 문자는 붙이지 않는다 — 종류는 `Kind:` 행이 말한다).
    nonisolated static func permissionString(from mode: UInt16) -> String {
        let flags = ["r", "w", "x"]
        var result = ""
        for shift in stride(from: 6, through: 0, by: -3) {
            let bits = (Int(mode) >> shift) & 0b111
            for (index, flag) in flags.enumerated() {
                result += (bits & (0b100 >> index)) != 0 ? flag : "-"
            }
        }
        return result
    }
}
