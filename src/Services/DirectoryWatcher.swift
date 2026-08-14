import Foundation

/// 표시 중 폴더 **1개**의 변경을 감시한다 (설계서 §3.4 / m3-impl T0·B8).
///
/// **비재귀 감시** (B8): `FSEventStreamCreate`는 본질적으로 재귀 감시라 깊은 하위 트리에서
/// 1만 개 파일이 생성되면 그 이벤트가 전부 유입돼 "대량 변경 중 UI 프리즈 없음" 기준을 위협한다.
/// 그래서 디렉터리 파일 디스크립터 하나에 대한 `DispatchSource.makeFileSystemObjectSource`를 쓴다 —
/// 커널은 **그 디렉터리의 직속 자식이 추가/삭제/이름변경될 때만** `.write`를 올리고, 하위 폴더
/// 내부의 변경은 그 하위 폴더의 fd에만 전달되므로 애초에 도달하지 않는다.
///
/// **300ms debounce** (설계 §3.4): 대량 변경이 연속으로 들어와도 갱신은 1회로 병합한다.
/// 병합 규칙은 `noteChange()`가 소유하고, 이 진입점을 파일시스템 없이 직접 호출해 단위 테스트한다.
///
/// **역할 범위** (B7): 이것은 **외부 변경 전용 보조 경로**다. 앱 자신의 조작 결과 반영
/// (트리 무효화·폴더 소실 판정·결과 항목 선택)은 `AppModel.applyOperationResult`가 계속 담당한다.
@MainActor
final class DirectoryWatcher {

    /// 설계서 §3.4가 정한 병합 간격.
    /// (기본 인자에서 참조하므로 `nonisolated` — MainActor 격리 상수는 기본값 위치에서 읽을 수 없다)
    nonisolated static let defaultDebounce: Duration = .milliseconds(300)

    /// 현재 감시 중인 폴더. 감시에 실패했으면(권한 없음 등) `nil`.
    private(set) var watchedURL: URL?

    /// 직속 자식이 바뀌었다 — debounce 창마다 최대 1회 호출된다.
    var onChange: ((URL) -> Void)?

    /// 감시 중인 폴더 **자신**이 삭제/이동됐다 (설계서 §6 — 상위로 자동 이동 트리거).
    var onVanished: ((URL) -> Void)?

    private let debounce: Duration
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?

    init(debounce: Duration = DirectoryWatcher.defaultDebounce) {
        self.debounce = debounce
    }

    deinit {
        // GCD 소스는 cancel 전까지 자기 자신을 붙들고 있어 fd가 남는다.
        // (MainActor 상태를 읽지만 값 캡처만 하고 콜백은 호출하지 않는다)
        source?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - 수명주기

    /// 감시 대상을 교체한다. 같은 폴더면 아무 것도 하지 않는다(재설치로 이벤트를 흘리지 않기 위함).
    func watch(_ url: URL) {
        let target = PathKey.directoryURL(url)
        if let watchedURL, PathKey.isSame(watchedURL, target) { return }

        stop()

        // `O_EVTONLY`는 "이벤트 수신 전용"이라 언마운트를 막지 않는다(일반 open은 볼륨을 붙든다).
        let descriptor = open(target.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // 권한이 없거나 사라진 폴더 — 감시 없이 계속한다(수동 새로고침은 그대로 동작).
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let flags = source?.data ?? []
            MainActor.assumeIsolated {
                self?.handle(flags)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()

        self.source = source
        self.watchedURL = target
    }

    /// 감시를 중단한다(윈도우 종료·경로 이동 전).
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
        watchedURL = nil
    }

    // MARK: - 이벤트 (DispatchSource와 단위 테스트가 공유하는 진입점)

    private func handle(_ flags: DispatchSource.FileSystemEvent) {
        // 감시 대상 자체가 없어진 경우가 우선이다 — 목록만 갱신하면 빈 화면에 갇힌다.
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            noteVanished()
            return
        }
        noteChange()
    }

    /// 직속 자식 변경 1건 유입. debounce 창 안의 연속 호출은 **1회 갱신으로 병합**된다.
    func noteChange() {
        guard let watchedURL else { return }
        debounceTask?.cancel()

        let interval = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            // 대기 중 감시 대상이 바뀌었으면 낡은 경로로 갱신을 통지하지 않는다.
            guard let current = self.watchedURL, PathKey.isSame(current, watchedURL) else { return }
            self.debounceTask = nil
            self.onChange?(current)
        }
    }

    /// 감시 대상 폴더 자신이 삭제/이동됐다. 대기 중인 갱신은 의미가 없어졌으므로 버린다.
    func noteVanished() {
        guard let watchedURL else { return }
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
        self.watchedURL = nil
        onVanished?(watchedURL)
    }
}
