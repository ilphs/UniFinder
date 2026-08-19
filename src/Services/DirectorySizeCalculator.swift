import Foundation

/// 폴더 크기 재귀 합산 (후속 T6 / 설계서 §3.2 폴더 크기 불변식 · D6).
///
/// **`actor`인 이유**: 하위 트리 순회는 항목 수에 비례하는 **블로킹 파일 IO**다. 메인 액터에서
/// 돌리면 10만 항목 폴더의 Get Info 창이 창 전체를 얼려버린다(§5 성능 요구: 메인스레드 블로킹 0).
/// 액터에 가두면 호출자는 `await`로만 접근하게 되어 실수로 동기 호출하는 경로가 생기지 않는다.
///
/// **계산 규칙은 설계서 §3.2의 불변식 3~6을 그대로 구현한다:**
/// - 논리 크기(`.fileSizeKey`)만 더한다. on-disk(할당) 크기는 보지 않는다.
/// - **하드링크는 중복 계산한다.** inode 집합을 들면 100만 항목에서 메모리가 선형으로 늘고,
///   이 값은 정확한 회계가 아니라 어림값이다 — 의도된 근사다.
/// - **심볼릭 링크는 따라가지도, 크기를 더하지도 않는다.** 따라가면 순환 링크에서 무한 순회하고
///   같은 실체를 여러 번 세게 된다.
/// - 읽을 수 없는 하위는 건너뛰고 계속하되 결과에 `isIncomplete`를 세운다.
actor DirectorySizeCalculator {

    /// 진행 상황 1회분.
    struct Progress: Sendable, Equatable {
        /// 지금까지 더한 논리 바이트.
        var bytes: Int64
        /// 지금까지 센 항목 수(폴더 포함, 건너뛴 심볼릭 링크 제외).
        var itemCount: Int
        /// 권한 등으로 읽지 못한 하위가 있었는지 — UI에 `(some items couldn't be read)`로 나타난다.
        var isIncomplete: Bool

        static let zero = Progress(bytes: 0, itemCount: 0, isIncomplete: false)
    }

    /// 점진 갱신 간격 (D6). 더 짧게 하면 대형 폴더에서 메인 액터가 갱신으로만 바빠진다.
    static let updateInterval: TimeInterval = 0.5

    /// 취소 확인 주기(항목 수). 매 항목마다 `Task.isCancelled`를 보면 순회가 눈에 띄게 느려진다.
    static let cancellationCheckStride = 256

    private let fileManager: FileManager

    init(fileManager: FileManager = FileManager.default) {
        self.fileManager = fileManager
    }

    /// 폴더 크기를 재귀로 합산한다.
    ///
    /// - Parameter onProgress: 최소 `updateInterval` 간격으로만 불린다(호출 폭주 방지).
    ///   마지막 값은 **반환값으로만** 전달되므로 호출자는 반환값도 반영해야 한다.
    /// - Throws: 작업이 취소되면 `CancellationError`. 대상이 아예 열리지 않으면
    ///   `CocoaError`(열거기 생성 실패 시 `.fileReadNoSuchFile`).
    /// - Returns: 최종 합계.
    func calculate(
        at url: URL,
        onProgress: @Sendable @escaping (Progress) async -> Void = { _ in }
    ) async throws -> Progress {
        try Task.checkCancellation()

        // **대상 자체의 부재는 에러다.** `FileManager.enumerator(at:)`는 존재하지 않는 경로에도
        // 열거기를 돌려주고(실패는 나중에 `errorHandler`로만 알려준다) 아무것도 내놓지 않는다 —
        // 그대로 두면 "지워진 폴더의 크기는 0바이트"라고 답하게 된다. 여기서 먼저 가른다.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard isDirectory.boolValue else {
            // 파일은 이 계산기의 대상이 아니다(파일 크기는 `FileItem.size`가 이미 안다).
            throw CocoaError(.fileReadUnknown)
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var progress = Progress.zero

        // 열거 중 만난 오류는 **던지지 않고** 표시만 한다(불변식 6) — 접근 불가 하위 하나 때문에
        // 폴더 전체의 크기를 포기하면 사용자는 아무 정보도 얻지 못한다.
        //
        // `errorHandler`는 열거 도중 동기적으로 불리므로 여기서 플래그만 세운다.
        let incomplete = IncompleteFlag()
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                incomplete.set()
                return true // 계속 순회한다
            }
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var lastEmit = Date()
        var sinceLastCancellationCheck = 0
        let keySet = Set(keys)

        // `for case let child as URL in enumerator`를 쓰지 않는다 — `NSEnumerator`의 `makeIterator()`는
        // 비동기 문맥에서 사용할 수 없다(Swift 6에서는 에러). `nextObject()`로 직접 돈다.
        while let child = enumerator.nextObject() as? URL {
            sinceLastCancellationCheck += 1
            if sinceLastCancellationCheck >= Self.cancellationCheckStride {
                sinceLastCancellationCheck = 0
                // 창을 닫거나 대상이 바뀌면 **즉시** 멈춰야 한다(§5 성능 요구).
                try Task.checkCancellation()
            }

            guard let values = try? child.resourceValues(forKeys: keySet) else {
                incomplete.set()
                continue
            }

            // 심볼릭 링크는 건너뛴다 — 크기도 더하지 않고 하위로 내려가지도 않는다.
            // (`FileManager.enumerator`는 원래 링크를 따라가지 않지만, 링크 자체의 크기를
            //  더하는 것도 같은 실체를 두 번 세는 일이라 막는다)
            if values.isSymbolicLink == true {
                continue
            }

            progress.itemCount += 1
            if values.isDirectory != true, let size = values.fileSize {
                progress.bytes += Int64(size)
            }

            let now = Date()
            if now.timeIntervalSince(lastEmit) >= Self.updateInterval {
                lastEmit = now
                var snapshot = progress
                snapshot.isIncomplete = incomplete.value
                await onProgress(snapshot)
            }
        }

        try Task.checkCancellation()
        progress.isIncomplete = incomplete.value
        return progress
    }

    /// `errorHandler` 클로저가 `Sendable`이라 캡처할 수 있는 최소 상태 상자.
    private final class IncompleteFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func set() {
            lock.lock(); defer { lock.unlock() }
            flag = true
        }

        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return flag
        }
    }
}
