import Foundation

/// 새 창을 열 때 넘기는 **시드 값** (다중 창 T4).
///
/// `WindowGroup(id:for:)`은 presentation value를 **창의 신원**으로 쓴다 — 이미 같은 값으로 열린
/// 창이 있으면 새 창을 만들지 않고 그 창을 앞으로 가져온다. 시드가 폴더 URL뿐이면
/// **⌘N을 연타해도 창이 하나만 생긴다**(같은 폴더에서 여는 것이 기본 동작이므로 매번 같은 값이다).
/// 그래서 매번 새로 만드는 `id: UUID`를 신원으로 싣고, 폴더는 부수 정보로 둔다.
///
/// `Codable`인 이유는 `WindowGroup(for:)`의 요구사항이자 macOS 창 상태 복원 때문이다.
/// 복원되는 값은 **창이 만들어진 시점의 폴더**이지 종료 시점의 폴더가 아니다 —
/// 탐색 위치는 `AppModel`(창 내부 상태)에 있고 시드에 되쓰지 않는다(스펙 문서에 명시).
struct WindowSeed: Hashable, Codable, Identifiable {

    /// 창의 신원. **같은 폴더로 창을 여러 개 열 수 있게 하는 유일한 근거**다.
    let id: UUID

    /// 새 창이 처음 표시할 폴더. `nil`이면 홈으로 시작한다.
    ///
    /// `URL`이 아니라 경로 문자열인 이유: `Codable` 표현이 안정적이고(파일 URL의 인코딩은
    /// 상대 경로/base URL 조합을 싣는다), `Hashable` 비교가 표기 차이에 흔들리지 않는다.
    let folderPath: String?

    init(id: UUID = UUID(), folderPath: String? = nil) {
        self.id = id
        self.folderPath = folderPath
    }

    init(id: UUID = UUID(), folderURL: URL?) {
        self.init(id: id, folderPath: folderURL.map { PathKey.exactPath($0) })
    }

    var folderURL: URL? {
        guard let folderPath, !folderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    /// 시드 없이 뜨는 창(런치 창·복원 실패)이 쓰는 기본값 — 홈 폴더.
    static func launchDefault() -> WindowSeed {
        WindowSeed(folderURL: FileManager.default.homeDirectoryForCurrentUser)
    }
}
