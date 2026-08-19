import Foundation

/// 우측 목록/좌측 트리에서 다루는 파일시스템 항목 1개.
///
/// 설계서 §3.2의 모델을 그대로 따른다. 열거 시점에 resource key를 일괄 prefetch해
/// 채워지므로, 이 구조체를 만든 뒤에는 추가 stat 호출이 필요 없다.
struct FileItem: Identifiable, Hashable, Sendable {

    /// 항목의 URL. 부모 URL에 이름을 덧붙여 만들기 때문에 호출자가 넘긴 경로 표기
    /// (`/var` vs `/private/var` 등)를 그대로 보존한다.
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    /// 심볼릭 링크 자체 여부(`isDirectory`는 링크가 가리키는 대상 기준).
    let isSymlink: Bool
    /// 폴더는 **항상 `nil`**이다 (설계서 §3.2 폴더 크기 불변식 1).
    ///
    /// 2026-08-19(후속 T6) 정정: Get Info 창은 폴더 크기를 비동기로 계산해 보여준다
    /// (`DirectorySizeCalculator`). 그것은 **이 값이 아니다** — 목록 열거가 하위 트리 순회를
    /// 떠안는 순간 §5 성능 목표가 무너지므로, 목록의 "크기" 컬럼은 폴더에서 계속 `--`다.
    let size: Int64?
    let modifiedAt: Date?
    /// "종류" 컬럼에 표시할 값. `UTType.localizedDescription` 기반.
    let typeDescription: String

    var id: URL { url }

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isHidden: Bool,
        isSymlink: Bool,
        size: Int64?,
        modifiedAt: Date?,
        typeDescription: String
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.size = size
        self.modifiedAt = modifiedAt
        self.typeDescription = typeDescription
    }
}
