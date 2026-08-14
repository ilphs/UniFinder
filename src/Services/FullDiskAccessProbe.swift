import Foundation

/// 전체 디스크 접근(FDA) 권한 판정 결과 (m3-impl T5 / B22).
///
/// **3상태인 이유**: TCC 보호 경로는 "권한 없음"과 "경로 없음"이 모두 실패로 관측된다.
/// `~/Library/Mail`은 Mail을 쓰지 않는 사용자에게 아예 존재하지 않아
/// `NSFileReadNoSuchFileError`가 나는데, 이를 미허용으로 해석하면 오탐이다(B22).
/// 그래서 "판정 불가"를 별도 상태로 두고, 판정 불가일 때는 **미허용으로 단정하지 않는다**
/// (설계 §8 리스크 표 — "FDA 감지 오탐 시 미허용으로 단정하지 않고 온화하게").
enum FullDiskAccessStatus: String, Equatable, Sendable {
    /// 보호 경로를 실제로 읽었다 — FDA 허용됨
    case granted
    /// 보호 경로가 존재하는데 읽기가 거부됐다 — FDA 미허용이 확실함
    case denied
    /// 후보 경로가 전부 없거나 알 수 없는 이유로 실패 — **미허용으로 단정하지 않는다**
    case undetermined
}

/// 단일 후보 경로 프로브의 관측 결과.
enum ProbeOutcome: Equatable, Sendable {
    /// 읽기 성공
    case readable
    /// 존재하지만 권한 거부 (`NSFileReadNoPermissionError` / `EACCES` / `EPERM`)
    case denied
    /// 경로 없음 (`NSFileReadNoSuchFileError` / `ENOENT`) — 판정 불가, 다음 후보로
    case missing
    /// 그 밖의 실패 — 판정 불가, 다음 후보로
    case inconclusive

    /// Foundation/POSIX 에러를 프로브 관측치로 매핑한다.
    ///
    /// `DirectoryError.map`과 달리 **"없음"을 "거부"로 접지 않는다** — 이 구분이 B22의 핵심이다.
    static func classify(_ error: Error) -> ProbeOutcome {
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .denied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .missing
            default:
                break
            }
        case NSPOSIXErrorDomain:
            switch Int32(nsError.code) {
            case EACCES, EPERM:
                return .denied
            case ENOENT, ENOTDIR:
                return .missing
            default:
                break
            }
        default:
            break
        }

        // 하위 에러에 원인이 담겨 오는 경우 한 단계 더 확인 (FileHandle 계열에서 발생)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return classify(underlying)
        }
        return .inconclusive
    }
}

/// FDA 없이는 읽을 수 없는 후보 경로 1개.
struct ProtectedPath: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        case directory
        case file
    }

    let url: URL
    let kind: Kind

    static func directory(_ path: String) -> ProtectedPath {
        ProtectedPath(url: URL(fileURLWithPath: path), kind: .directory)
    }

    static func file(_ path: String) -> ProtectedPath {
        ProtectedPath(url: URL(fileURLWithPath: path), kind: .file)
    }
}

/// 보호 경로 접근 가능 여부를 관측하는 추상화 (M2의 `DirectoryListing`/`ConflictResolving`과 동일한 주입 패턴).
///
/// 실제 TCC 권한 상태에 의존하지 않고 판정 로직을 단위 테스트로 고정하기 위해 존재한다(B22 수용 기준).
protocol ProtectedPathProbing: Sendable {

    /// 시도 순서대로 나열한 후보 경로들.
    var candidates: [ProtectedPath] { get }

    /// 후보 1개를 실제로 읽어보고 관측 결과를 돌려준다. 프롬프트를 띄우거나 예외를 던지지 않는다.
    func probe(_ candidate: ProtectedPath) -> ProbeOutcome
}

extension ProtectedPathProbing {

    /// 후보들을 순서대로 시도해 3상태를 판정한다 — **판정 규칙의 단일 지점**(테스트 대상).
    ///
    /// 규칙(B22):
    /// 1. 하나라도 읽혔으면 `.granted` (즉시 확정 — 읽힌 이상 다른 후보의 실패는 권한 문제가 아니다)
    /// 2. 읽힌 것이 없고 **명시적 거부**가 있었으면 `.denied`
    /// 3. 그 외(전부 없음/알 수 없음)는 `.undetermined` — 미허용으로 단정하지 않는다
    func evaluateStatus() -> FullDiskAccessStatus {
        var sawDenial = false
        for candidate in candidates {
            switch probe(candidate) {
            case .readable:
                return .granted
            case .denied:
                sawDenial = true
            case .missing, .inconclusive:
                continue
            }
        }
        return sawDenial ? .denied : .undetermined
    }
}

/// `FileManager` 기반 실제 프로브 (프로덕션 구현체).
///
/// **후보 선정 기준**: TCC의 전체 디스크 접근에만 묶여 있고, 접근 시도가 **사용자 프롬프트를
/// 유발하지 않는** 경로만 쓴다. 데스크탑/다운로드/서류는 개별 TCC 프롬프트를 띄우므로
/// (그리고 FDA 없이도 승인될 수 있으므로) 프로브로 쓰지 않는다.
///
/// **B21 주의**: TCC 승인은 코드 서명 신원에 묶인다. 현재 `project.yml`은 ad-hoc 서명
/// (`CODE_SIGN_IDENTITY: "-"`, `ENABLE_HARDENED_RUNTIME: NO`)이므로 개발 빌드에서는
/// 빌드할 때마다 FDA 승인이 초기화되어 재승인이 필요하다. 서명 전환은 릴리스 직전 별도 작업이다
/// (m3-impl B21 — 방침 (b)). 이 프로브의 판정 자체는 서명 방식과 무관하게 동작한다.
struct FullDiskAccessProbe: ProtectedPathProbing {

    let candidates: [ProtectedPath]

    init(candidates: [ProtectedPath] = FullDiskAccessProbe.defaultCandidates) {
        self.candidates = candidates
    }

    /// 기본 후보 — 앞에서부터 "대부분의 Mac에 존재하는" 순서.
    static var defaultCandidates: [ProtectedPath] {
        let home = NSHomeDirectory()
        return [
            // 사용자 TCC 데이터베이스 — 거의 모든 Mac에 존재하고 FDA 없이는 읽히지 않는다
            .directory("\(home)/Library/Application Support/com.apple.TCC"),
            // Safari 데이터 — Safari를 한 번이라도 실행했으면 존재
            .directory("\(home)/Library/Safari"),
            // Mail — B22가 지목한 "없을 수 있는" 경로. 없으면 판정 불가로 넘어간다
            .directory("\(home)/Library/Mail"),
            // 시스템 TCC 데이터베이스 — 위가 전부 없을 때의 최후 후보
            .file("/Library/Application Support/com.apple.TCC/TCC.db"),
        ]
    }

    func probe(_ candidate: ProtectedPath) -> ProbeOutcome {
        // `FileManager`는 Sendable이 아니므로 저장하지 않고 호출마다 지역 인스턴스를 만든다
        // (프로브는 앱 활성화 시점에만 도는 저빈도 경로라 비용이 문제되지 않는다).
        let fileManager = FileManager()
        do {
            switch candidate.kind {
            case .directory:
                // 목록 1건만 확인하면 충분하다. 열거 자체가 권한 검사 지점이다.
                _ = try fileManager.contentsOfDirectory(atPath: candidate.url.path)
            case .file:
                let handle = try FileHandle(forReadingFrom: candidate.url)
                defer { try? handle.close() }
                _ = try handle.read(upToCount: 1)
            }
            return .readable
        } catch {
            return ProbeOutcome.classify(error)
        }
    }
}
