import Foundation

/// 마운트된 볼륨 열거의 **단일 권위** (후속 T1).
///
/// 예전에는 `TreeModel.localVolumeURLs()`가 `FileManager.mountedVolumeURLs`를 직접 불렀다.
/// 디스크 용량 창(T8)이 같은 목록을 필요로 하면서 그 로직을 복제할 상황이 됐고, 복제하면
/// "사이드바에는 보이는데 용량 창에는 없는 볼륨" 같은 어긋남이 곧바로 생긴다.
/// 그래서 열거·필터 규칙을 여기로 모으고 두 곳이 **같은 함수**를 부른다.
///
/// **필터 규칙은 이전 구현 그대로다**(동작 변경 없음 — 사이드바 회귀 테스트가 그대로 통과해야 한다):
/// - `.skipHiddenVolumes` 옵션
/// - `volumeIsLocal == true` — 네트워크 볼륨 제외(설계서 §1.2 비목표)
/// - `volumeIsBrowsable`는 키가 없으면 `true`로 본다(보수적으로 표시)
/// - 열거 자체가 실패하면 `/` 하나로 폴백한다 — 사이드바에서 볼륨 섹션이 통째로 사라지는 것보다 낫다
///
/// **열거기를 주입 가능하게 둔다** (`FullDiskAccessModel.opener` 선례): 테스트가 실제 마운트
/// 상태에 의존하면 개발 머신마다 결과가 달라져 단언을 쓸 수 없다.
struct VolumeService: Sendable {

    /// 볼륨 열거 원본. 주입 시 `nil` 반환은 "열거 실패"를 뜻한다.
    typealias Enumerator = @Sendable (_ keys: [URLResourceKey], _ options: FileManager.VolumeEnumerationOptions) -> [URL]?

    /// URL 하나에서 볼륨 속성을 읽는 경로. 테스트가 가짜 볼륨의 속성을 정할 수 있게 분리한다.
    ///
    /// `URLResourceValues`를 그대로 쓰지 않는 이유: 볼륨 관련 프로퍼티(`volumeIsLocal` 등)는
    /// **get-only**라 테스트가 값을 조립할 수 없다. 필요한 3개만 담은 값 타입으로 좁힌다.
    typealias AttributeReader = @Sendable (_ url: URL) -> VolumeAttributes?

    /// 볼륨 1개의 판정 근거. `nil` 필드는 "키가 없음"을 뜻한다.
    struct VolumeAttributes: Sendable, Equatable {
        var isLocal: Bool?
        var isBrowsable: Bool?
        var name: String?

        init(isLocal: Bool? = nil, isBrowsable: Bool? = nil, name: String? = nil) {
            self.isLocal = isLocal
            self.isBrowsable = isBrowsable
            self.name = name
        }
    }

    /// 트리/용량 창이 함께 쓰는 조회 키.
    static let resourceKeys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeNameKey]

    /// 열거 실패 시의 폴백 — 루트 볼륨 하나.
    static let fallbackURLs: [URL] = [URL(fileURLWithPath: "/", isDirectory: true)]

    private let enumerator: Enumerator
    private let attributeReader: AttributeReader

    init(
        enumerator: @escaping Enumerator = { keys, options in
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: options)
        },
        attributeReader: @escaping AttributeReader = { url in
            guard let values = try? url.resourceValues(forKeys: Set(VolumeService.resourceKeys)) else { return nil }
            return VolumeAttributes(
                isLocal: values.volumeIsLocal,
                isBrowsable: values.volumeIsBrowsable,
                name: values.volumeName
            )
        }
    ) {
        self.enumerator = enumerator
        self.attributeReader = attributeReader
    }

    /// 필터를 통과한 볼륨 1개 — URL과 **그 판정에 쓴 속성**을 함께 들고 있다.
    ///
    /// 속성을 같이 돌려주는 이유(reviewer major #4): 예전에는 `localVolumeURLs()`가 볼륨마다
    /// `attributeReader`를 부른 뒤 그 결과를 버렸고, 호출자(용량 창)가 이름을 얻으려고
    /// `displayName(of:)`으로 **같은 디스크 조회를 한 번 더** 했다. 볼륨 속성 조회는 마운트 상태에
    /// 따라 수십 ms가 걸릴 수 있는 IO라, 볼륨 수만큼 중복 비용이 그대로 쌓인다.
    struct LocalVolume: Sendable, Equatable {
        let url: URL
        /// 열거 폴백(루트 1개)으로 만들어진 항목은 속성을 읽은 적이 없으므로 `nil`이다.
        let attributes: VolumeAttributes?

        /// 표시 이름 — 이미 읽은 속성을 재사용한다(추가 조회 없음).
        var displayName: String { VolumeService.displayName(for: url, attributes: attributes) }
    }

    /// 사이드바/용량 창에 보여줄 **로컬·탐색 가능** 볼륨 목록 (속성 포함).
    ///
    /// 돌려주는 URL은 폴더 표준형(후행 슬래시)이다 — `TreeModel.canonicalDirectoryURL`과 같은 규칙.
    ///
    /// **디스크 IO를 한다.** 메인 액터에서 부르지 말 것(용량 창은 `Task.detached`에서 부른다).
    func localVolumes() -> [LocalVolume] {
        guard let volumes = enumerator(Self.resourceKeys, [.skipHiddenVolumes]) else {
            return Self.fallbackURLs.map { LocalVolume(url: $0, attributes: nil) }
        }

        return volumes.compactMap { url in
            guard let attributes = attributeReader(url) else { return nil }
            let isLocal = attributes.isLocal ?? false
            let isBrowsable = attributes.isBrowsable ?? true
            guard isLocal, isBrowsable else { return nil }
            return LocalVolume(url: Self.canonicalDirectoryURL(url), attributes: attributes)
        }
    }

    /// URL만 필요한 호출자(사이드바 트리)를 위한 얇은 래퍼.
    func localVolumeURLs() -> [URL] {
        localVolumes().map(\.url)
    }

    /// 볼륨 속성 조회 — 용량 창(T8)이 이름/판정을 재사용한다.
    func attributes(of url: URL) -> VolumeAttributes? {
        attributeReader(url)
    }

    /// 볼륨 표시 이름(`volumeName`). 없으면 마지막 경로 요소, 그것도 비면 경로 전체.
    ///
    /// **속성을 이미 들고 있다면 `LocalVolume.displayName`을 쓸 것** — 이 함수는 조회를 새로 한다.
    func displayName(of url: URL) -> String {
        Self.displayName(for: url, attributes: attributeReader(url))
    }

    /// 이름 결정 규칙 자체 — 조회는 하지 않는다(이미 읽은 속성을 그대로 쓴다).
    /// 규칙이 한 곳에만 있어야 "사이드바와 용량 창의 볼륨 이름이 다르다"가 생기지 않는다.
    static func displayName(for url: URL, attributes: VolumeAttributes?) -> String {
        if let name = attributes?.name, !name.isEmpty {
            return name
        }
        let last = url.lastPathComponent
        return last.isEmpty ? url.path : last
    }

    /// `TreeModel.canonicalDirectoryURL`과 동일 규칙(심볼릭 링크를 해석하지 않는 표준형).
    /// 트리가 이 서비스의 결과를 인덱스 키로 그대로 쓰므로 두 규칙이 어긋나면 안 된다.
    static func canonicalDirectoryURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard !path.isEmpty else { return URL(fileURLWithPath: "/", isDirectory: true) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
