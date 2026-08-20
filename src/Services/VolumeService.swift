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
        /// 분리 가능 여부(마운트된 디스크 이미지·외장 디스크). Eject 적격 판정의 정본이다.
        var isEjectable: Bool?
        /// 물리적으로 뺄 수 있는 매체(USB 등). `isEjectable` 키가 없을 때의 폴백이다.
        var isRemovable: Bool?
        /// 이 볼륨이 부팅 볼륨(`/`)인지. **경로가 아니라 이 값으로 루트를 판정한다** —
        /// 외장 디스크로 부팅한 머신에서는 루트 볼륨이 `isEjectable == true`로 보고되므로
        /// 경로만 보면 "부팅 디스크 꺼내기"를 사용자에게 제안하게 된다.
        var isRootFileSystem: Bool?

        init(
            isLocal: Bool? = nil,
            isBrowsable: Bool? = nil,
            name: String? = nil,
            isEjectable: Bool? = nil,
            isRemovable: Bool? = nil,
            isRootFileSystem: Bool? = nil
        ) {
            self.isLocal = isLocal
            self.isBrowsable = isBrowsable
            self.name = name
            self.isEjectable = isEjectable
            self.isRemovable = isRemovable
            self.isRootFileSystem = isRootFileSystem
        }
    }

    /// 트리/용량 창이 함께 쓰는 조회 키.
    ///
    /// **Eject 판정 키(`isEjectable`/`isRemovable`/`isRootFileSystem`)를 여기에 함께 둔다**:
    /// 우클릭 시점에 따로 조회하면 응답 없는 마운트가 하나 끼는 순간 컨텍스트 메뉴 자체가 멈춘다
    /// (이 조회는 마운트 상태에 따라 수십 ms가 걸리는 IO다). 열거할 때 한 번에 읽어 두고
    /// 그 값을 메뉴 구성에 재사용한다.
    static let resourceKeys: [URLResourceKey] = [
        .volumeIsLocalKey,
        .volumeIsBrowsableKey,
        .volumeNameKey,
        .volumeIsEjectableKey,
        .volumeIsRemovableKey,
        .volumeIsRootFileSystemKey,
    ]

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
                name: values.volumeName,
                isEjectable: values.volumeIsEjectable,
                isRemovable: values.volumeIsRemovable,
                isRootFileSystem: values.volumeIsRootFileSystem
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

        /// 사용자가 꺼낼 수 있는 볼륨인지 — 이미 읽은 속성을 재사용한다(추가 조회 없음).
        var isEjectable: Bool { VolumeService.isEjectable(url: url, attributes: attributes) }
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

    // MARK: - Eject (마운트된 디스크 이미지·외장 볼륨 꺼내기)

    /// 이 볼륨에 `Eject`를 제안해도 되는지 — **조회는 하지 않는다**(이미 읽은 속성만 본다).
    ///
    /// 규칙:
    /// - 부팅 볼륨은 절대 대상이 아니다. 판정은 `isRootFileSystem`이 정본이고, 키가 없으면
    ///   경로가 `/`인지로 폴백한다(외장 부팅 머신에서 부팅 디스크를 꺼내라고 권하지 않기 위함).
    /// - `isEjectable`이 정본, 없으면 `isRemovable`로 폴백한다. **둘 다 없으면 `false`** —
    ///   여기서는 보수적으로 기울어야 한다(`isBrowsable`의 "없으면 표시" 기본값과 반대 방향):
    ///   잘못 표시된 Eject는 마운트 해제라는 파괴적 방향으로 작동한다.
    static func isEjectable(url: URL, attributes: VolumeAttributes?) -> Bool {
        let isRoot = attributes?.isRootFileSystem ?? (canonicalDirectoryURL(url).path == "/")
        guard !isRoot else { return false }
        guard let attributes else { return false }
        return attributes.isEjectable ?? attributes.isRemovable ?? false
    }

    /// 언마운트 실행부. 주입 가능하게 두어 테스트가 실제 볼륨을 건드리지 않게 한다.
    /// 성공은 `nil`, 실패는 원인 오류를 돌려준다.
    typealias Unmounter = @Sendable (_ url: URL) async -> Error?

    /// `FileManager.unmountVolume` 기반 기본 구현.
    ///
    /// **`NSWorkspace.unmountAndEjectDevice(at:)`를 쓰지 않는 이유**: 그쪽은 동기 호출이라
    /// 메인 액터에서 부르면 볼륨이 응답하기까지 UI가 통째로 멈춘다(설계서 §5 "메인 블로킹 0").
    /// `FileManager` 쪽은 완료 핸들러 기반이고, 볼륨이 사용 중이면 **어느 앱이 붙잡고 있는지를
    /// OS가 직접 안내**한다 — 우리가 그 대화상자를 다시 만들 이유가 없다(그래서 `.withoutUI`를
    /// 주지 않는다).
    ///
    /// **`.allPartitionsAndEjectDisk`가 반드시 필요하다** (2026-08-20 실측):
    /// 빈 옵션(`[]`)으로 부르면 `/Volumes/X`는 사라지지만 **디스크 이미지는 그대로 붙어 있다**
    /// (`hdiutil info`에 image-path가 남는다). 사용자가 기대하는 "꺼내기"는 Finder의 Eject —
    /// 즉 장치까지 떼어내는 것이고, 그렇지 않으면 dmg 파일을 지우거나 옮길 수 없는 상태가
    /// 조용히 남는다. 이 옵션은 그 디스크의 모든 파티션을 내리고 장치를 분리한다(Finder와 동일).
    static let defaultUnmounter: Unmounter = { url in
        await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            FileManager.default.unmountVolume(at: url, options: [.allPartitionsAndEjectDisk]) { error in
                continuation.resume(returning: error)
            }
        }
    }

    // MARK: - 용량 (후속 T8 · 상태바 표시가 함께 쓴다)

    /// 볼륨 1개의 용량 조회 결과. 필드가 `nil`이면 그 값만 못 읽은 것이다.
    struct Capacity: Sendable, Equatable {
        var total: Int64?
        var available: Int64?

        init(total: Int64? = nil, available: Int64? = nil) {
            self.total = total
            self.available = available
        }
    }

    /// 용량 조회 주입점 — 테스트가 실제 디스크 상태에 묶이지 않게 한다. `nil`은 "조회 실패"다.
    typealias CapacityReader = @Sendable (_ url: URL) -> Capacity?

    /// D1 — 여유 공간은 `forImportantUsage`가 정본이고, 없으면 `volumeAvailableCapacity`로 폴백한다.
    ///
    /// 두 키의 의미가 다르다: 전자는 "정리 가능한 공간을 포함해 실제로 쓸 수 있는 양"이고
    /// 후자는 "지금 당장 비어 있는 양"이다. Finder가 보여주는 값은 전자에 가깝다.
    ///
    /// **디스크 IO다.** 메인 액터에서 부르지 말 것 — 응답 없는 마운트가 끼면 수 초까지 걸린다.
    /// 이 구현이 `DiskUsageModel`에서 여기로 올라온 이유: 상태바(하단 우측 용량 표시)가 같은 값을
    /// 필요로 하게 됐고, 두 화면이 서로 다른 규칙으로 계산하면 "창과 상태바의 숫자가 다르다"가
    /// 곧바로 버그로 보고된다. 볼륨에 관한 규칙은 이 타입 하나가 갖는다.
    static let defaultCapacityReader: CapacityReader = { url in
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        // `forImportantUsage`는 이미 `Int64?`, 나머지는 `Int?`라 타입을 명시적으로 맞춘다.
        let important: Int64? = values.volumeAvailableCapacityForImportantUsage
        let fallback: Int64? = values.volumeAvailableCapacity.map { Int64($0) }
        let total: Int64? = values.volumeTotalCapacity.map { Int64($0) }
        return Capacity(total: total, available: important ?? fallback)
    }

    /// "이 경로가 속한 볼륨"의 루트 URL을 찾는 경로. 주입 가능하게 둔다(테스트).
    typealias VolumeLocator = @Sendable (_ url: URL) -> URL?

    /// `.volumeURLKey` 기반 기본 구현. **디스크 IO다** — 메인 액터에서 부르지 말 것.
    ///
    /// 돌려주는 URL은 폴더 표준형이라 `localVolumes()`의 결과와 같은 기준으로 비교할 수 있다.
    static let defaultVolumeLocator: VolumeLocator = { url in
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let volume = values.volume
        else { return nil }
        return canonicalDirectoryURL(volume)
    }
}
