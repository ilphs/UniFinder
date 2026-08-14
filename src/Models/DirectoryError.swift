import Foundation

/// 디렉토리 열거 실패 사유. UI는 이 값을 인라인 empty-state로만 표시한다
/// (UI설계 §8 — 탐색을 막는 모달 금지).
enum DirectoryError: Error, Equatable, Sendable {
    /// 읽기 권한 없음 (FDA 미허용 포함)
    case accessDenied
    /// 경로가 존재하지 않음
    case notFound
    /// 경로가 디렉토리가 아님
    case notADirectory
    /// 그 외 (Foundation 에러 메시지 보존)
    case unknown(String)

    /// empty-state 제목
    var title: String {
        switch self {
        case .accessDenied: return "접근 권한 없음"
        case .notFound: return "폴더를 찾을 수 없음"
        case .notADirectory: return "폴더가 아님"
        case .unknown: return "폴더를 열 수 없음"
        }
    }

    /// empty-state 본문 (UI설계 §4.2 문구)
    var message: String {
        switch self {
        case .accessDenied: return "이 폴더에 접근할 권한이 없습니다."
        case .notFound: return "이 폴더는 더 이상 존재하지 않습니다."
        case .notADirectory: return "선택한 항목은 폴더가 아닙니다."
        case .unknown(let detail): return detail
        }
    }

    /// Foundation/POSIX 에러를 도메인 에러로 매핑한다.
    static func map(_ error: Error) -> DirectoryError {
        if let already = error as? DirectoryError { return already }

        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .accessDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .notFound
            default:
                break
            }
        case NSPOSIXErrorDomain:
            switch Int32(nsError.code) {
            case EACCES, EPERM:
                return .accessDenied
            case ENOENT:
                return .notFound
            case ENOTDIR:
                return .notADirectory
            default:
                break
            }
        default:
            break
        }

        // 하위 에러에 원인이 담겨 오는 경우(NSUnderlyingError) 한 단계 더 확인
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== nsError {
            return map(underlying)
        }

        return .unknown(nsError.localizedDescription)
    }
}
