import Foundation

/// Get Info 창이 겨냥하는 대상 (후속 T5 / D7).
///
/// **`WindowSeed`와 정반대로 `UUID`를 넣지 않는다.** `WindowSeed`가 UUID를 든 이유는 "같은 폴더로
/// 창을 여러 개 열 수 있어야 한다"였다. 정보 창은 그 반대가 맞다 — 같은 파일의 정보 창이 두 개
/// 떠 있을 이유가 없고, `WindowGroup(for:)`은 **같은 값 = 같은 창**으로 취급하므로 값이 URL만으로
/// 결정되면 재요청이 기존 창을 앞으로 가져온다. 그것이 정확히 우리가 원하는 동작이다.
///
/// **심볼릭 링크를 해석하지 않는다** (D3 / 설계서 §6 규약): `Open`은 의도를 다루므로 링크를 따라가지만
/// Get Info는 관찰을 다룬다. 사용자가 링크 파일의 정보를 물었으면 링크 자체의 크기·날짜를 답해야 하고,
/// 해석된 경로는 창의 `Original:` 행에 병기한다. 그래서 여기서 `AppModel.resolveTarget(of:)`도,
/// `resolvingSymlinksInPath()`도 부르지 않는다 — 이 규칙은 `InfoTargetSymlinkTests`가 봉인한다.
///
/// `standardizedFileURL`만 적용한다(`..`·중복 슬래시 제거). 이는 링크 해석이 아니라 표기 정리다.
struct InfoTarget: Codable, Hashable, Sendable {

    let url: URL

    init(url: URL) {
        // 표기만 정리한다. `resolvingSymlinksInPath()`를 부르면 위 규약이 깨진다.
        self.url = url.standardizedFileURL
    }

    /// 창 제목에 쓰는 이름.
    var displayName: String {
        let last = url.lastPathComponent
        return last.isEmpty ? url.path : last
    }
}
