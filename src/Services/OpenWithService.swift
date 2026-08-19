import AppKit
import Foundation
import UniformTypeIdentifiers

/// "이 파일을 열 수 있는 앱" 하나.
struct ApplicationOption: Hashable, Sendable {

    let url: URL
    /// 메뉴/팝업에 표시할 이름(확장자 제거된 앱 이름).
    let name: String
    /// 현재 기본 앱인지 — 메뉴에서 맨 위에 두고 `(default)` 표기를 붙인다.
    let isDefault: Bool
}

/// Open With(다음 프로그램으로 열기)와 기본 앱 지정 (후속 T4·T7 / D5).
///
/// **LaunchServices 호출을 전부 주입 가능하게 감싼다** (`FullDiskAccessModel.opener` 선례).
/// 이유가 T7에서 특히 중요하다: 기본 앱 지정은 **사용자 머신의 시스템 설정을 실제로 바꾸는**
/// 조작이라, 테스트가 진짜 API를 부르면 테스트를 돌린 사람의 PDF 기본 앱이 바뀐다.
/// 그런 테스트는 존재해서는 안 된다 — mock만 쓴다.
struct OpenWithService: Sendable {

    typealias CandidatesProvider = @Sendable (_ fileURL: URL) -> [URL]
    typealias DefaultApplicationProvider = @Sendable (_ fileURL: URL) -> URL?
    typealias DisplayNameProvider = @Sendable (_ applicationURL: URL) -> String
    typealias ContentTypeProvider = @Sendable (_ fileURL: URL) -> UTType?
    /// 한 번만 그 앱으로 연다(기본 앱은 바뀌지 않는다).
    ///
    /// **파일 배열을 받고 결과를 되돌려준다**(reviewer minor #6·#7):
    /// - 배열인 이유 — Finder처럼 **선택 전체**를 여는 것이 Open With의 의미다.
    /// - `completion`인 이유 — `NSWorkspace.open`은 실행 실패(앱이 지워졌다·손상됐다·권한이 없다)를
    ///   completion handler로만 알린다. 예전에는 `nil`을 넘겨 그 실패를 통째로 삼켰고,
    ///   사용자는 아무 일도 일어나지 않는 화면만 봤다. 실패는 `Error`로, 성공은 `nil`로 온다.
    typealias Launcher = @Sendable (
        _ fileURLs: [URL],
        _ applicationURL: URL,
        _ completion: @escaping @Sendable (Error?) -> Void
    ) -> Void
    /// 파일 1개의 기본 앱을 바꾼다.
    typealias FileDefaultSetter = @Sendable (_ applicationURL: URL, _ fileURL: URL) async throws -> Void
    /// 해당 UTType **전체**의 기본 앱을 바꾼다 — 시스템 전역 변경이라 확인 alert가 선행돼야 한다.
    typealias ContentTypeDefaultSetter = @Sendable (_ applicationURL: URL, _ contentType: UTType) async throws -> Void

    private let candidatesProvider: CandidatesProvider
    private let defaultApplicationProvider: DefaultApplicationProvider
    private let displayNameProvider: DisplayNameProvider
    private let contentTypeProvider: ContentTypeProvider
    private let launcher: Launcher
    private let fileDefaultSetter: FileDefaultSetter
    private let contentTypeDefaultSetter: ContentTypeDefaultSetter

    init(
        candidatesProvider: @escaping CandidatesProvider = { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
        defaultApplicationProvider: @escaping DefaultApplicationProvider = {
            NSWorkspace.shared.urlForApplication(toOpen: $0)
        },
        displayNameProvider: @escaping DisplayNameProvider = { $0.deletingPathExtension().lastPathComponent },
        contentTypeProvider: @escaping ContentTypeProvider = { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        },
        launcher: @escaping Launcher = { fileURLs, applicationURL, completion in
            NSWorkspace.shared.open(
                fileURLs,
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                completion(error)
            }
        },
        fileDefaultSetter: @escaping FileDefaultSetter = { applicationURL, fileURL in
            try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpenFileAt: fileURL)
        },
        contentTypeDefaultSetter: @escaping ContentTypeDefaultSetter = { applicationURL, contentType in
            try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: contentType)
        }
    ) {
        self.candidatesProvider = candidatesProvider
        self.defaultApplicationProvider = defaultApplicationProvider
        self.displayNameProvider = displayNameProvider
        self.contentTypeProvider = contentTypeProvider
        self.launcher = launcher
        self.fileDefaultSetter = fileDefaultSetter
        self.contentTypeDefaultSetter = contentTypeDefaultSetter
    }

    // MARK: - 후보 조회 (T4)

    /// 이 파일을 열 수 있는 앱 목록. **기본 앱이 맨 앞**이고 나머지는 LaunchServices 순서를 유지한다.
    ///
    /// 같은 앱이 여러 경로로 잡히는 경우(예: `/Applications`와 `~/Applications`)는 URL 기준으로
    /// 중복 제거한다 — 메뉴에 같은 이름이 두 번 뜨면 사용자가 무엇을 고를지 알 수 없다.
    func applications(for fileURL: URL) -> [ApplicationOption] {
        let defaultURL = defaultApplicationProvider(fileURL)
        var seen: Set<String> = []
        var options: [ApplicationOption] = []

        func append(_ url: URL, isDefault: Bool) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            options.append(ApplicationOption(url: url, name: displayNameProvider(url), isDefault: isDefault))
        }

        if let defaultURL { append(defaultURL, isDefault: true) }
        for url in candidatesProvider(fileURL) {
            append(url, isDefault: false)
        }
        return options
    }

    /// 이번 한 번만 그 앱으로 연다. **기본 앱은 바뀌지 않는다** — 기본 앱 변경은
    /// Get Info 창의 "Open with:"만 할 수 있다(UI설계 §6 주석).
    ///
    /// - Parameters:
    ///   - fileURLs: 열 파일 **전체**(Finder와 같은 규칙 — 선택한 만큼 연다). 비어 있으면 아무 일도 하지 않는다.
    ///   - completion: 실패 사유(성공이면 `nil`). 호출자는 이것을 사용자에게 **반드시 전달해야 한다** —
    ///     삼키면 "눌렀는데 아무 일도 안 일어난다"가 된다(reviewer minor #7).
    ///     AppKit이 임의 스레드에서 부르므로 메인 액터 작업은 호출자가 옮긴다.
    func open(
        _ fileURLs: [URL],
        with applicationURL: URL,
        completion: @escaping @Sendable (Error?) -> Void = { _ in }
    ) {
        guard !fileURLs.isEmpty else { return }
        launcher(fileURLs, applicationURL, completion)
    }

    /// 대상 파일의 UTType — `Change All…`의 적용 범위를 정하고 확인 문구에도 쓴다.
    func contentType(of fileURL: URL) -> UTType? {
        contentTypeProvider(fileURL)
    }

    // MARK: - 기본 앱 지정 (T7)

    /// **파일 1개**의 기본 앱을 바꾼다 (Get Info의 "Open with:" 팝업 기본 동작).
    /// 되돌리기가 같은 팝업에서 한 번에 되므로 확인을 받지 않는다.
    func setDefaultApplication(_ applicationURL: URL, forFileAt fileURL: URL) async throws {
        try await fileDefaultSetter(applicationURL, fileURL)
    }

    /// **해당 종류 전체**의 기본 앱을 바꾼다 (`[Change All…]`).
    ///
    /// 이 함수를 부르기 전에 반드시 확인 alert를 띄운다(UI설계 §7.8) — 시스템 전역 설정이라
    /// 취소한 사용자의 머신이 바뀌면 되돌릴 방법을 우리가 안내할 수 없다.
    /// 확인/취소 판정은 호출자(뷰)의 몫이고, 여기서는 "부르면 바뀐다"만 보장한다.
    func setDefaultApplication(_ applicationURL: URL, forContentType contentType: UTType) async throws {
        try await contentTypeDefaultSetter(applicationURL, contentType)
    }
}
