import Foundation
import UniformTypeIdentifiers

/// 비동기 디렉토리 열거 서비스 (설계서 §3.1 Services 레이어).
///
/// 성능 핵심(설계서 §3.2): 필요한 resource key를 `contentsOfDirectory`에서 **한 번에 prefetch**
/// 하고, 항목별 개별 stat 호출을 하지 않는다. "종류" 문자열도 UTType 식별자 키로 캐시해
/// 10만 항목에서 `localizedDescription`을 반복 계산하지 않는다.
actor DirectoryLoader: DirectoryListing {

    static let shared = DirectoryLoader()

    /// UTType 식별자 → 로컬라이즈된 종류 설명 캐시 (T3: 항목별 재계산 방지)
    private var typeDescriptionCache: [String: String] = [:]

    /// 취소 확인 주기(항목 수). 매 항목 검사 시 오버헤드가 커서 배치로 확인한다.
    private static let cancellationCheckInterval = 256

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .isHiddenKey,
        .contentTypeKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
    ]

    init() {}

    // MARK: - DirectoryListing

    func list(at url: URL, showHidden: Bool) async throws -> [FileItem] {
        try Task.checkCancellation()

        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DirectoryError.notFound
        }
        guard isDirectory.boolValue else {
            throw DirectoryError.notADirectory
        }

        let keys = Array(Self.resourceKeys)
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden {
            options.insert(.skipsHiddenFiles)
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: Self.enumerationURL(for: url),
                includingPropertiesForKeys: keys,
                options: options
            )
        } catch {
            throw DirectoryError.map(error)
        }

        try Task.checkCancellation()

        var items: [FileItem] = []
        items.reserveCapacity(contents.count)

        for (index, entryURL) in contents.enumerated() {
            if index % Self.cancellationCheckInterval == 0 {
                try Task.checkCancellation()
            }
            // 앱 내부 구현 아티팩트(대소문자 rename staging)는 목록에 노출하지 않는다 (m3-impl T0/B23).
            // FSEvents 자동 갱신이 붙으면 두 단계 rename 사이에 이 이름이 목록에 뜰 수 있다.
            guard !entryURL.lastPathComponent.hasPrefix(FileOperations.renameStagingPrefix) else { continue }
            items.append(makeItem(parent: url, entryURL: entryURL))
        }

        try Task.checkCancellation()
        return items
    }

    /// 하위 폴더만 필요한 좌측 트리용 경로(T4). 열거 자체는 `list`와 동일하다.
    func listDirectories(at url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await list(at: url, showHidden: showHidden).filter(\.isDirectory)
    }

    // MARK: - 열거 대상 해석

    /// 실제 열거에 사용할 URL. **자식 URL을 만드는 부모 표기(`makeItem(parent:)`)와는 별개다.**
    ///
    /// 위 가드의 `fileExists(atPath:isDirectory:)`는 `stat(2)` 의미론이라 심볼릭 링크를 **따라가지만**,
    /// `contentsOfDirectory(at:)`(URL 버전)는 링크를 따라가지 않아 링크 자체를 `ENOTDIR`로 거절한다
    /// (`~/Dropbox` 같은 FileProvider 도메인 마운트 링크가 대표 사례 — 트리에서 선택하면
    /// `.notADirectory`("Not a Folder")로 떨어졌다). 두 의미론이 어긋나면 "폴더 맞다"고 통과시킨
    /// 가드 바로 다음 줄에서 "폴더가 아니다"로 실패하는 모순이 생긴다.
    ///
    /// 그래서 **열거 대상만** 링크를 해석하고, 자식 URL의 부모 표기는 호출자가 준 원본 URL을
    /// 그대로 유지한다. 트리 `nodeIndex` 키 / `navigation.currentURL` / 주소창이 사용자가 고른
    /// 경로 표기(`/Users/x/Dropbox`)로 일관되게 남아야 하기 때문
    /// (`TreeModel.canonicalDirectoryURL`이 링크를 해석하지 않는 설계 의도와 같은 규칙).
    private static func enumerationURL(for url: URL) -> URL {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path != url.path else { return url }

        // 깨진 링크·순환 링크 방어: `resolvingSymlinksInPath()`는 해석에 실패하면 원래 경로를
        // 그대로 돌려주거나 존재하지 않는 경로를 만들어낼 수 있다. 해석 결과가 실제 폴더일 때만
        // 채택하고, 아니면 원본으로 되돌려 기존 에러 매핑(`.notFound`/`.notADirectory`)을 살린다.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return url }

        return resolved
    }

    // MARK: - 항목 생성

    private func makeItem(parent: URL, entryURL: URL) -> FileItem {
        // `contentsOfDirectory`는 심볼릭 링크가 걸린 부모 경로를 해석해 돌려주는 경우가 있어
        // (`/var` → `/private/var`), 호출자가 넘긴 부모 URL 기준으로 자식 URL을 다시 구성한다.
        // 트리/주소창/선택 상태가 하나의 경로 표기로 일관되게 유지되어야 하기 때문.
        let name = entryURL.lastPathComponent
        let values = try? entryURL.resourceValues(forKeys: Self.resourceKeys)

        let isSymlink = values?.isSymbolicLink ?? false
        var isDirectory = values?.isDirectory ?? false

        // 심볼릭 링크는 리소스 값이 링크 자체를 가리킬 수 있어 대상 타입을 한 번 더 확인한다.
        // (링크는 전체 항목 중 극소수라 성능 영향이 없다)
        if isSymlink {
            var targetIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &targetIsDirectory) {
                isDirectory = targetIsDirectory.boolValue
            }
        }

        let url = parent.appendingPathComponent(name, isDirectory: isDirectory)
        let isHidden = values?.isHidden ?? name.hasPrefix(".")
        let size: Int64? = isDirectory ? nil : values?.fileSize.map(Int64.init)
        let modifiedAt = values?.contentModificationDate
        let typeDescription = typeDescription(
            for: values?.contentType,
            isDirectory: isDirectory,
            pathExtension: entryURL.pathExtension
        )

        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isHidden: isHidden,
            isSymlink: isSymlink,
            size: size,
            modifiedAt: modifiedAt,
            typeDescription: typeDescription
        )
    }

    /// UTType 식별자 기준 캐시. 미상 타입은 확장자 기준으로 폴백한다.
    private func typeDescription(
        for contentType: UTType?,
        isDirectory: Bool,
        pathExtension: String
    ) -> String {
        if isDirectory { return "Folder" }

        let cacheKey = contentType?.identifier ?? "ext:\(pathExtension.lowercased())"
        if let cached = typeDescriptionCache[cacheKey] {
            return cached
        }

        let description: String
        if let localized = contentType?.localizedDescription, !localized.isEmpty {
            description = localized
        } else if !pathExtension.isEmpty {
            description = "\(pathExtension.uppercased()) File"
        } else {
            description = "File"
        }

        typeDescriptionCache[cacheKey] = description
        return description
    }
}
