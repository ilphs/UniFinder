import Foundation

/// 파일 조작 서비스 (설계서 §3.1 Services / 설계 결정 #4 — Finder 위임이 아닌 자체 구현).
///
/// **의존 방향**: 이 타입은 ViewModel/AppKit을 import하지 않는다. 사용자 질의가 필요한
/// 이름 충돌은 `ConflictResolving` 프로토콜로 주입받는다(architect B4).
///
/// **파괴적 작업 의미론** (m2-impl T0/B3 — 즉흥 설계 금지, 전부 여기서 확정):
/// - 덮어쓰기: 기존 대상을 **휴지통으로 보낸 뒤** 복사 (설계 결정 #3 영구 삭제 금지)
/// - 폴더 덮어쓰기: 재귀 병합이 아니라 **대체** (Finder 관례)
/// - 자기 자신/자기 하위 경로가 대상이면 거부 (무한 재귀 방지)
/// - 심볼릭 링크는 **링크 자체**를 복사 (`copyItem`은 타겟을 따라가지 않는다)
/// - 볼륨 간 이동은 `moveItem` 실패(EXDEV) 시 copy + 원본 휴지통으로 폴백
/// - 대소문자만 바꾸는 rename은 자기 자신을 중복으로 오판하지 않는다 (APFS 대소문자 비구분)
actor FileOperations: FileOperating {

    static let shared = FileOperations()

    /// `FileManager.default` 공유 인스턴스 대신 전용 인스턴스를 쓴다 (m2-impl T0).
    /// 대량 순회 중 delegate/상태가 다른 소비자와 섞이지 않도록 하기 위함.
    private let fileManager = FileManager()

    /// 보호 대상 판정에 쓰는 홈 루트.
    ///
    /// 주입 가능한 이유는 **테스트 안전성**이다: 실제 홈을 대상으로 "가드가 없으면 어떻게 되는지"를
    /// 검증하면 회귀 테스트 자체가 홈 디렉터리를 옮기거나 지울 수 있다. 임시 폴더를 홈으로
    /// 지정하면 같은 코드 경로를 파괴적 위험 없이 검증할 수 있다.
    private let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    // MARK: - 복사 / 이동

    func copy(
        items: [URL],
        to destination: URL,
        resolver: any ConflictResolving,
        progress: OperationProgressSink?
    ) async -> OperationResult {
        await transfer(kind: .copy, items: items, to: destination, resolver: resolver, progress: progress)
    }

    func move(
        items: [URL],
        to destination: URL,
        resolver: any ConflictResolving,
        progress: OperationProgressSink?
    ) async -> OperationResult {
        await transfer(kind: .move, items: items, to: destination, resolver: resolver, progress: progress)
    }

    /// 항목 단위 순회 (설계 결정 #4). 일부 실패해도 나머지를 계속 처리한다.
    private func transfer(
        kind: FileOperationKind,
        items: [URL],
        to destination: URL,
        resolver: any ConflictResolving,
        progress: OperationProgressSink?
    ) async -> OperationResult {
        var result = OperationResult()
        let total = items.count
        defer { progress?.finish() }

        guard isDirectory(destination) else {
            for item in items {
                result.failures.append(OperationFailure(url: item, error: .sourceMissing))
            }
            return result
        }

        // "모두 적용"은 이 호출 스코프의 로컬 값이다 (architect B4 — 전역 actor 상태 금지).
        var applyToAll: ConflictResolution?

        loop: for (index, source) in items.enumerated() {
            if Task.isCancelled {
                result.isCancelled = true
                break loop
            }
            progress?.send(OperationProgress(kind: kind, completed: index, total: total, current: source))

            do {
                let outcome = try await performTransfer(
                    kind: kind,
                    source: source,
                    destination: destination,
                    resolver: resolver,
                    applyToAll: &applyToAll,
                    remainingCount: total - index - 1
                )
                switch outcome {
                case .produced(let url):
                    result.produced.append(url)
                case .skipped:
                    result.skipped.append(source)
                case .cancelled:
                    result.isCancelled = true
                    break loop
                }
            } catch {
                result.failures.append(OperationFailure(url: source, error: FileOperationError.map(error)))
            }
        }

        progress?.send(OperationProgress(kind: kind, completed: total, total: total, current: nil))
        return result
    }

    private enum ItemOutcome {
        case produced(URL)
        case skipped
        case cancelled
    }

    private func performTransfer(
        kind: FileOperationKind,
        source: URL,
        destination: URL,
        resolver: any ConflictResolving,
        applyToAll: inout ConflictResolution?,
        remainingCount: Int
    ) async throws -> ItemOutcome {
        guard itemExists(source) else { throw FileOperationError.sourceMissing }

        // 이동은 원본을 원위치에서 없앤다 — 휴지통/이름변경과 **같은 판정**으로 위험 대상을 막는다.
        // (`trash(items:)`/`rename`만 막으면 "잘라내기 → 붙여넣기" 경로로 홈/볼륨 루트가 새어 나간다)
        if kind == .move, isProtected(source) {
            throw FileOperationError.protectedTarget
        }

        // 폴더 A를 A 또는 A 하위로 복사/이동 금지 (무한 재귀 방지 — m2-impl T0)
        //
        // **문자열 비교만으로는 부족하다** (M2 백로그 B1 — M3 D&D 선처리): 트리 노드는 심볼릭 링크를
        // 그대로 보존하므로(`TreeNode.isSymlink`), "폴더 A를 A/sub를 가리키는 별칭 노드에 드롭"이
        // 드래그 한 번으로 가능하다. 이때 destination(`/root/alias`)과 source(`/root/A`)는 문자열
        // 접두사가 전혀 겹치지 않아 `PathKey.isSameOrDescendant`가 무한 재귀 복사/이동을 통과시킨다.
        // 강화판(`isSameOrDescendant`)은 항목 식별자 + 심볼릭 링크 해석까지 함께 본다.
        guard !isSameOrDescendant(destination, of: source) else {
            throw FileOperationError.destinationInsideSource
        }

        let sourceParent = source.deletingLastPathComponent()
        // "같은 폴더" 판정도 표기가 아니라 **실제로 도달하는 폴더**로 한다 (M2 백로그 B2): 별칭 경로로
        // 원본의 부모 폴더에 붙여넣기/드롭하면 문자열 비교는 "다른 폴더"로 오판해 자동 넘버링(copy)/
        // no-op(move) 규칙 대신 충돌 시트를 띄운다 — M3 D&D의 "같은 폴더 드롭 = 무동작" 수용 기준 위반.
        let isSameFolder = isSameDirectory(sourceParent, destination)
        var target = destination.appendingPathComponent(source.lastPathComponent)

        if isSameFolder {
            switch kind {
            case .move:
                // 잘라내기 후 같은 폴더에 붙여넣기 = no-op (Win10 동작)
                return .skipped
            default:
                // 같은 폴더에 복사 = 충돌 질의 없이 자동 "둘 다 유지" (UI설계 §7.1)
                target = uniqueURL(for: target)
            }
        } else if itemExists(target) {
            let resolution: ConflictResolution
            if let stored = applyToAll {
                resolution = stored
            } else {
                let decision = await resolver.resolve(
                    makeConflict(
                        kind: kind,
                        source: source,
                        destination: target,
                        remainingCount: remainingCount
                    )
                )
                if decision.applyToAll {
                    applyToAll = decision.resolution
                }
                resolution = decision.resolution
            }

            switch resolution {
            case .cancel:
                return .cancelled
            case .skip:
                return .skipped
            case .keepBoth:
                target = uniqueURL(for: target)
            case .replace:
                // 대상이 사실은 원본 자신이면 덮어쓰기는 **원본을 지우는 것**이다.
                // 대소문자 비구분 볼륨의 표기 차이(`/Users/admin` vs `/Users/Admin`)나
                // 심볼릭 링크 경유 경로로 같은 파일에 도달할 수 있으므로 반드시 먼저 막는다.
                guard !isSameItem(source, target) else {
                    throw FileOperationError.destinationIsSource
                }
                // 대상이 원본의 **조상**이면 덮어쓰기는 원본과 그 형제들까지 지우는 것이다.
                // 재현: `Documents/Documents`를 `Documents`의 상위 폴더에 붙여넣기 → 대상이
                // 원본의 부모 폴더가 되어 `trashExisting`이 부모를 통째로 휴지통으로 보낸다.
                // (`destination이 source 안`을 막는 L133 가드는 방향이 반대라 이 경우를 못 잡는다)
                guard !isSameOrDescendant(source, of: target) else {
                    throw FileOperationError.sourceInsideDestination
                }
                // 덮어쓰기 대상도 휴지통행이다 — `trash(items:)`와 같은 판정으로 위험 대상을 막는다.
                guard !isProtected(target) else {
                    throw FileOperationError.protectedTarget
                }
                // 폴더 덮어쓰기는 병합이 아니라 대체 — 기존 대상을 통째로 휴지통으로 보낸다.
                try trashExisting(target)
            }
        }

        switch kind {
        case .move:
            try moveItem(source, to: target)
        default:
            try copyItem(source, to: target)
        }
        return .produced(target)
    }

    // MARK: - 휴지통

    func trash(items: [URL], progress: OperationProgressSink?) async -> OperationResult {
        var result = OperationResult()
        let total = items.count
        defer { progress?.finish() }

        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                result.isCancelled = true
                break
            }
            progress?.send(OperationProgress(kind: .trash, completed: index, total: total, current: item))

            guard !isProtected(item) else {
                result.failures.append(OperationFailure(url: item, error: .protectedTarget))
                continue
            }
            guard itemExists(item) else {
                result.failures.append(OperationFailure(url: item, error: .sourceMissing))
                continue
            }
            do {
                // 설계 결정 #3 — 영구 삭제는 제공하지 않는다.
                try fileManager.trashItem(at: item, resultingItemURL: nil)
                result.produced.append(item)
            } catch {
                result.failures.append(OperationFailure(url: item, error: FileOperationError.map(error)))
            }
        }

        progress?.send(OperationProgress(kind: .trash, completed: total, total: total, current: nil))
        return result
    }

    // MARK: - 이름 변경

    func rename(item: URL, to newName: String) async -> OperationResult {
        var result = OperationResult()
        do {
            let name = try Self.normalizedName(newName)
            // 부모를 읽을 수 없는 경우(권한 없음)에는 "없음"으로 단정하지 않는다 —
            // 그렇게 하면 권한 실패가 `.sourceMissing`으로 잘못 보고된다.
            if !itemExists(item), fileManager.isReadableFile(atPath: item.deletingLastPathComponent().path) {
                throw FileOperationError.sourceMissing
            }
            guard !isProtected(item) else { throw FileOperationError.protectedTarget }

            let parent = item.deletingLastPathComponent()
            let target = parent.appendingPathComponent(name)

            // 이름이 **표기까지** 그대로면 파일시스템을 건드리지 않는다.
            // `PathKey.key`는 소문자 정규화라 여기서 쓰면 "abc" → "ABC"가 무동작이 된다.
            guard !PathKey.isSameExactPath(target, item) else {
                result.produced = [item]
                return result
            }

            // APFS는 기본이 대소문자 비구분이라 "abc" → "ABC"에서 fileExists가 true를 준다.
            // 자기 자신은 중복으로 보지 않는다 (m2-impl T0).
            // 정규화 키가 같은데 표기가 다르다 = 대소문자만 바뀐 rename.
            let isCaseOnlyChange = PathKey.isSame(target, item)
            if !isCaseOnlyChange, itemExists(target) {
                throw FileOperationError.nameExists
            }

            if isCaseOnlyChange {
                try renameChangingCaseOnly(item, to: target, in: parent)
            } else {
                try fileManager.moveItem(at: item, to: target)
            }
            result.produced = [target]
        } catch {
            result.failures = [OperationFailure(url: item, error: FileOperationError.map(error))]
        }
        return result
    }

    /// 대소문자 rename에 쓰는 임시 이름 접두사 (m3-impl T0/B23).
    ///
    /// FSEvents 자동 갱신이 붙은 뒤로는 이 staging 파일이 **목록에 순간 노출될 수 있다**.
    /// 내부 구현 아티팩트이므로 `DirectoryLoader`가 열거 단계에서 걸러낸다 — 상수를 공유해
    /// 양쪽 규칙이 어긋나지 않게 한다.
    static let renameStagingPrefix = ".unifinder-rename-"

    /// 대소문자만 바뀌는 rename은 대소문자 비구분 볼륨에서 `moveItem`이 "이미 존재"로 실패한다.
    /// 임시 이름을 경유해 두 단계로 수행하고, 실패하면 원래 이름으로 되돌린다.
    private func renameChangingCaseOnly(_ item: URL, to target: URL, in parent: URL) throws {
        let staging = parent.appendingPathComponent("\(Self.renameStagingPrefix)\(UUID().uuidString)")
        try fileManager.moveItem(at: item, to: staging)
        do {
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.moveItem(at: staging, to: item)
            throw error
        }
    }

    // MARK: - 새 폴더

    /// **원시 연산** — 이름이 이미 있으면 `.nameExists`로 거부한다.
    /// "새 폴더 2" 넘버링은 `FileOperating.createFolder(in:uniqueBaseName:)` 래퍼가 담당한다
    /// (레이어 분리: 여기서 조용히 다른 이름으로 만들면 호출자가 의도를 통제할 수 없다).
    func createFolder(in parent: URL, name: String) async -> OperationResult {
        var result = OperationResult()
        do {
            let base = try Self.normalizedName(name)
            guard isDirectory(parent) else { throw FileOperationError.sourceMissing }

            let target = parent.appendingPathComponent(base, isDirectory: true)
            guard !itemExists(target) else { throw FileOperationError.nameExists }

            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            result.produced = [target]
        } catch {
            result.failures = [OperationFailure(url: parent, error: FileOperationError.map(error))]
        }
        return result
    }

    // MARK: - 파일시스템 원시 연산

    private func copyItem(_ source: URL, to target: URL) throws {
        do {
            // `copyItem`은 심볼릭 링크를 따라가지 않고 링크 자체를 복사한다 (테스트계획서 §4.2).
            try fileManager.copyItem(at: source, to: target)
        } catch {
            throw FileOperationError.map(error)
        }
    }

    private func moveItem(_ source: URL, to target: URL) throws {
        do {
            try fileManager.moveItem(at: source, to: target)
        } catch {
            guard Self.isCrossDeviceError(error) else { throw FileOperationError.map(error) }
            // 볼륨 간 이동 폴백: 복사 후 원본을 휴지통으로 (설계 결정 #3 — 원본 영구 삭제 금지)
            do {
                try fileManager.copyItem(at: source, to: target)
                try fileManager.trashItem(at: source, resultingItemURL: nil)
            } catch {
                throw FileOperationError.map(error)
            }
        }
    }

    private func trashExisting(_ url: URL) throws {
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw FileOperationError.map(error)
        }
    }

    // MARK: - 경로 판정

    /// `fileExists`는 심볼릭 링크를 따라가므로 끊어진 링크를 "없음"으로 본다.
    /// `attributesOfItem`(lstat)으로 링크 자체의 존재까지 확인한다.
    private func itemExists(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// 위험 대상 가드 (m2-impl T0): 볼륨 루트·홈 루트는 삭제/이름변경/이동/덮어쓰기 금지.
    ///
    /// **모든 파괴적 경로가 이 판정 하나를 공유한다** — `trash(items:)`, `rename`,
    /// `move`의 원본, `.replace`의 덮어쓰기 대상. 경로별로 따로 구현하면 한 곳이 빠진다
    /// (실제로 M2 리뷰에서 transfer 경로 누락이 blocker로 잡혔다).
    ///
    /// **경로 문자열 비교만으로는 부족하다** (M2 재리뷰 blocker): macOS의 firmlink 때문에
    /// `/Users/admin`과 `/System/Volumes/Data/Users/admin`은 **같은 디렉터리**인데 문자열은 다르다.
    /// firmlink는 심볼릭 링크가 아니라 `standardizedFileURL`·`resolvingSymlinksInPath`로도 접히지 않으므로,
    /// 문자열 비교만 하면 별칭 경로로 홈/볼륨 루트 가드가 그대로 뚫린다.
    /// 그래서 `isSameItem`(항목 식별자 비교)을 같이 쓴다 — 판정 기법을 한 곳에서 공유한다.
    private func isProtected(_ url: URL) -> Bool {
        if PathKey.key(url) == "/" { return true }
        if let values = try? url.resourceValues(forKeys: [.isVolumeKey]), values.isVolume == true { return true }
        // 표기가 어떻든 실제로 홈 루트/볼륨 루트 그 자체에 도달하면 보호한다.
        if isSameItem(url, homeDirectory) { return true }
        if isSameItem(url, URL(fileURLWithPath: "/")) { return true }
        return false
    }

    /// `url`이 `base` 자신이거나 그 하위인지 — **파괴적 판정 전용** 강화판.
    ///
    /// 경로 문자열 판정(`PathKey.isSameOrDescendant`)으로 먼저 거르고, 걸리지 않으면 조상 사슬을
    /// 항목 식별자로 비교한다. 심볼릭 링크·firmlink 별칭 경로는 문자열 접두사가 전혀 겹치지 않아
    /// (`/tmp/alias/x` vs `/tmp/real/x`) 문자열 판정만으로는 포함 관계를 놓치기 때문이다.
    ///
    /// 조상 사슬 비교만으로는 **`url` 자신이 별칭인 경우**를 놓친다 (M2 백로그 B1): `/root/alias`가
    /// `/root/A/sub`를 가리키면 사슬은 `/root/alias` → `/root` → `/`로 올라가 `/root/A`를 스치지도
    /// 않는다. 그래서 심볼릭 링크를 접은 경로로 한 번 더 확인한다.
    /// (firmlink는 `resolvingSymlinksInPath`로 접히지 않지만, 그쪽은 사슬 + `isSameItem`이 잡는다)
    private func isSameOrDescendant(_ url: URL, of base: URL) -> Bool {
        if ancestorChainContains(base, from: url) { return true }
        let resolved = url.resolvingSymlinksInPath()
        guard !PathKey.isSame(resolved, url) else { return false }
        return ancestorChainContains(base, from: resolved)
    }

    /// `url`의 조상 사슬(자기 자신 포함)에 `base`와 **같은 항목**이 있는지.
    /// 사슬은 루트에서 끝나므로 순회는 항상 종료한다.
    private func ancestorChainContains(_ base: URL, from url: URL) -> Bool {
        if PathKey.isSameOrDescendant(url, of: base) { return true }
        var current: URL? = url
        while let candidate = current {
            if isSameItem(candidate, base) { return true }
            current = PathKey.parent(of: candidate)
        }
        return false
    }

    /// 두 경로가 **실제로 같은 폴더에 도달**하는지 (M2 백로그 B2 — "같은 폴더" 규칙 전용).
    ///
    /// `isSameItem`은 항목 식별자를 lstat 의미론으로 읽는다 — 경로의 **마지막 요소가 심볼릭 링크**면
    /// 링크 자신의 식별자가 나오므로 "별칭 폴더 노드"(`<root>/alias -> <root>/real`)를 원본의 부모와
    /// 같다고 보지 못한다. 여기서 묻는 것은 "항목이 같은가"가 아니라 "어느 폴더에 놓이는가"이므로
    /// 링크를 접은 경로로 한 번 더 확인한다.
    /// (`isSameItem` 자체를 바꾸면 "심볼릭 링크를 그 타겟으로 덮어쓰기" 같은 정상 조작까지 막힌다)
    private func isSameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        if isSameItem(lhs, rhs) { return true }
        return isSameItem(lhs.resolvingSymlinksInPath(), rhs.resolvingSymlinksInPath())
    }

    /// 두 URL이 **실제로 같은 항목**인지.
    ///
    /// 경로 문자열 비교(대소문자 정규화 포함)로 먼저 거르고, 그래도 다르면 파일시스템이 주는
    /// 항목 식별자로 확인한다 — 심볼릭 링크로 만든 별칭 경로처럼 표기가 완전히 달라도
    /// 같은 파일에 도달할 수 있기 때문이다.
    private func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        if PathKey.isSame(lhs, rhs) { return true }
        guard let lhsID = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let rhsID = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return lhsID.isEqual(rhsID)
    }

    private func makeConflict(
        kind: FileOperationKind,
        source: URL,
        destination: URL,
        remainingCount: Int
    ) -> FileConflict {
        let sourceMeta = metadata(of: source)
        let destinationMeta = metadata(of: destination)
        return FileConflict(
            kind: kind,
            source: source,
            destination: destination,
            sourceSize: sourceMeta.size,
            sourceModifiedAt: sourceMeta.modifiedAt,
            destinationSize: destinationMeta.size,
            destinationModifiedAt: destinationMeta.modifiedAt,
            remainingCount: remainingCount
        )
    }

    private func metadata(of url: URL) -> (size: Int64?, modifiedAt: Date?) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        else { return (nil, nil) }
        let size: Int64? = (values.isDirectory ?? false) ? nil : values.fileSize.map(Int64.init)
        return (size, values.contentModificationDate)
    }

    // MARK: - 이름 규칙

    /// "둘 다 유지" 넘버링: `name 2.ext`, `name 3.ext` … (Finder 관례)
    private func uniqueURL(for url: URL) -> URL {
        Self.uniqueURL(for: url) { [fileManager] candidate in
            fileManager.fileExists(atPath: candidate.path)
                || (try? fileManager.attributesOfItem(atPath: candidate.path)) != nil
        }
    }

    /// 넘버링 규칙 본체 — 존재 판정을 주입받아 단위 테스트에서 파일시스템 없이 검증할 수 있다.
    static func uniqueURL(for url: URL, exists: (URL) -> Bool) -> URL {
        let directory = url.deletingLastPathComponent()
        let fullName = url.lastPathComponent as NSString
        let ext = fullName.pathExtension
        let base = fullName.deletingPathExtension

        for index in 2...1000 {
            let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !exists(candidate) { return candidate }
        }
        let fallback = ext.isEmpty
            ? "\(base) \(UUID().uuidString)"
            : "\(base) \(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(fallback)
    }

    /// 이름 검증 (UI설계 §7.2): 빈 이름 / `/` / `:` / 길이 초과 금지.
    static func normalizedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileOperationError.invalidName("이름을 입력하세요.")
        }
        guard !trimmed.contains("/") else {
            throw FileOperationError.invalidName("이름에 \"/\" 문자를 사용할 수 없습니다.")
        }
        guard !trimmed.contains(":") else {
            throw FileOperationError.invalidName("이름에 \":\" 문자를 사용할 수 없습니다.")
        }
        guard trimmed != ".", trimmed != ".." else {
            throw FileOperationError.invalidName("사용할 수 없는 이름입니다.")
        }
        guard trimmed.utf8.count <= 255 else {
            throw FileOperationError.invalidName("이름이 너무 깁니다 (최대 255바이트).")
        }
        return trimmed
    }

    /// 볼륨 간 이동 판정 — `moveItem`이 EXDEV로 실패하는 경우.
    static func isCrossDeviceError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, Int32(nsError.code) == EXDEV { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return isCrossDeviceError(underlying)
        }
        return false
    }
}
