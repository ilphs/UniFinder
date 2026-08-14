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
                at: url,
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
        if isDirectory { return "폴더" }

        let cacheKey = contentType?.identifier ?? "ext:\(pathExtension.lowercased())"
        if let cached = typeDescriptionCache[cacheKey] {
            return cached
        }

        let description: String
        if let localized = contentType?.localizedDescription, !localized.isEmpty {
            description = localized
        } else if !pathExtension.isEmpty {
            description = "\(pathExtension.uppercased()) 파일"
        } else {
            description = "파일"
        }

        typeDescriptionCache[cacheKey] = description
        return description
    }
}
