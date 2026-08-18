import Foundation

/// 파일 조작 종류 (설계서 §3.1 FileOperations).
enum FileOperationKind: String, Sendable, Equatable {
    case copy
    case move
    case trash
    case rename
    case createFolder

    /// 상태바 미니 표시 문구 (UI설계 §5). 진행률 시트 본체는 M3.
    var progressLabel: String {
        switch self {
        case .copy: return "Copying…"
        case .move: return "Moving…"
        case .trash: return "Moving to Trash…"
        case .rename: return "Renaming…"
        case .createFolder: return "Creating Folder…"
        }
    }

    /// 실패/완료 문구에 끼워 넣는 **과거분사** ("… couldn't be copied").
    /// 영어 문장 구조상 동사 원형이 아니라 이 형태여야 자연스럽다 (2026-08-18 영어화).
    var completionVerb: String {
        switch self {
        case .copy: return "copied"
        case .move: return "moved"
        case .trash: return "moved to Trash"
        case .rename: return "renamed"
        case .createFolder: return "created"
        }
    }

    /// 작업 자체를 가리키는 **명사구** ("Copy was stopped."). 과거분사로는 문장이 안 된다.
    var actionNoun: String {
        switch self {
        case .copy: return "Copy"
        case .move: return "Move"
        case .trash: return "Move to Trash"
        case .rename: return "Rename"
        case .createFolder: return "New Folder"
        }
    }
}

/// 이름 충돌 1건의 정보 (UI설계 §7.1 — 원본/대상 메타를 시트에 그대로 표시한다).
struct FileConflict: Sendable, Equatable {

    let kind: FileOperationKind
    let source: URL
    let destination: URL
    let sourceSize: Int64?
    let sourceModifiedAt: Date?
    let destinationSize: Int64?
    let destinationModifiedAt: Date?
    /// 이 충돌 이후 남은 항목 수 — "Apply to the remaining N items" 문구에 쓴다.
    let remainingCount: Int

    var name: String { destination.lastPathComponent }
}

/// 충돌 해결 방법 (UI설계 §7.1).
enum ConflictResolution: String, Sendable, Equatable {
    /// 기존 대상을 **휴지통으로 보낸 뒤** 교체 (설계 결정 #3 — 영구 삭제 금지)
    case replace
    /// `name 2.ext` 로 둘 다 유지 (Finder 관례)
    case keepBoth
    case skip
    /// 전체 작업 중단. 이미 처리된 항목은 유지한다.
    case cancel
}

/// 충돌 응답 + "모두 적용" 여부.
///
/// "모두 적용"은 **작업 1건 범위의 로컬 값**이다 (m2-impl T0/B4).
/// `FileOperations`(actor)가 전역 상태로 들고 있으면 동시에 진행되는 다른 작업에 새어 나간다.
struct ConflictDecision: Sendable, Equatable {

    let resolution: ConflictResolution
    let applyToAll: Bool

    init(resolution: ConflictResolution, applyToAll: Bool = false) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }

    static let replace = ConflictDecision(resolution: .replace)
    static let keepBoth = ConflictDecision(resolution: .keepBoth)
    static let skip = ConflictDecision(resolution: .skip)
    static let cancel = ConflictDecision(resolution: .cancel)
}

/// 진행 상황 1틱. M2는 상태바 미니 표시만 소비하고, M3 진행률 시트가 같은 타입을 재사용한다.
struct OperationProgress: Sendable, Equatable {

    let kind: FileOperationKind
    let completed: Int
    let total: Int
    let current: URL?

    var fraction: Double {
        guard total > 0 else { return 1 }
        return min(1, Double(completed) / Double(total))
    }

    var isFinished: Bool { completed >= total }
}

/// 조작 실패 사유 → 사용자 문구 (UI설계 §8).
enum FileOperationError: Error, Equatable, Sendable {

    case accessDenied
    case destinationReadOnly
    case insufficientSpace
    case sourceMissing
    /// 폴더를 자기 자신 또는 자기 하위 경로로 복사/이동하려는 시도 (무한 재귀 방지)
    case destinationInsideSource
    /// 덮어쓰기 대상이 사실은 원본 자신인 경우.
    /// 대소문자 비구분 볼륨의 표기 차이나 심볼릭 링크 별칭 경로로 같은 파일에 도달하면
    /// "덮어쓰기"가 곧 원본 삭제가 되므로 거부한다 (M2 리뷰 blocker).
    case destinationIsSource
    /// 덮어쓰기 대상이 원본의 **조상**인 경우 (`Documents/Documents`를 `Documents`의 상위 폴더로 붙여넣기).
    /// 대상을 휴지통으로 보내면 원본과 그 형제 항목까지 통째로 사라지므로 거부한다 (M2 재리뷰 blocker).
    /// `destinationIsSource`(대상 == 원본)와 달리 여기서는 대상이 원본을 **포함**한다.
    case sourceInsideDestination
    /// 볼륨 루트·홈 루트 등 삭제/이름변경을 막아야 하는 대상
    case protectedTarget
    case invalidName(String)
    case nameExists
    /// 대소문자만 바꾸는 rename의 **임시 이름 복구까지 실패**한 경우 (M2 백로그 — 예전에는 `try?`로 삼켰다).
    ///
    /// 이 경로에서는 항목이 `FileOperations.renameStagingPrefix` 이름으로 디스크에 남는데,
    /// `DirectoryLoader`가 그 접두사를 열거 단계에서 걸러내므로 **목록에도 나타나지 않는다** —
    /// 사용자 눈에는 파일이 소실된 것으로 보인다. 그래서 남은 경로를 문구에 반드시 실어 보낸다
    /// (손으로 되돌릴 수 있는 유일한 단서다).
    case renameStagingStranded(stagedPath: String, cause: String, recoveryFailure: String)
    case unknown(String)

    var message: String {
        switch self {
        case .accessDenied:
            return "You don't have permission."
        case .destinationReadOnly:
            return "The destination is read-only."
        case .insufficientSpace:
            return "There isn't enough space on the destination volume."
        case .sourceMissing:
            return "The item couldn't be located."
        case .destinationInsideSource:
            return "A folder can't be moved into itself or one of its own subfolders."
        case .destinationIsSource:
            return "The destination is the same as the source."
        case .sourceInsideDestination:
            return "The item being replaced contains the source, so the source would be deleted too."
        case .protectedTarget:
            return "This item can't be changed."
        case .invalidName(let reason):
            return reason
        case .nameExists:
            return "An item with that name already exists."
        case .renameStagingStranded(let stagedPath, let cause, let recoveryFailure):
            return "The rename failed (\(cause)) and the original name couldn't be restored (\(recoveryFailure)). "
                + "The item is left under a temporary name at '\(stagedPath)' — please rename it back in Finder."
        case .unknown(let detail):
            return detail
        }
    }

    /// Foundation/POSIX 에러를 도메인 에러로 매핑한다.
    static func map(_ error: Error) -> FileOperationError {
        if let already = error as? FileOperationError { return already }
        if error is CancellationError { return .unknown("The operation was cancelled.") }

        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .accessDenied
            case NSFileWriteVolumeReadOnlyError:
                return .destinationReadOnly
            case NSFileWriteOutOfSpaceError:
                return .insufficientSpace
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .sourceMissing
            case NSFileWriteFileExistsError:
                return .nameExists
            case NSFileWriteInvalidFileNameError:
                return .invalidName("That name can't be used.")
            default:
                break
            }
        case NSPOSIXErrorDomain:
            switch Int32(nsError.code) {
            case EACCES, EPERM:
                return .accessDenied
            case EROFS:
                return .destinationReadOnly
            case ENOSPC, EDQUOT:
                return .insufficientSpace
            case ENOENT:
                return .sourceMissing
            case EEXIST, ENOTEMPTY:
                return .nameExists
            case ENAMETOOLONG:
                return .invalidName("The name is too long.")
            default:
                break
            }
        default:
            break
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return map(underlying)
        }
        return .unknown(nsError.localizedDescription)
    }
}

/// 항목 1개의 실패 기록. 다중 작업은 실패해도 나머지를 계속 처리하고 목록으로 모아 보고한다.
struct OperationFailure: Sendable, Equatable {
    let url: URL
    let error: FileOperationError
}

/// 조작 1건의 결과.
struct OperationResult: Sendable, Equatable {

    /// 새로 만들어졌거나 이동/변경된 결과 URL — 작업 후 선택 대상이 된다.
    var produced: [URL] = []
    /// 사용자가 "건너뛰기"를 선택했거나 no-op으로 처리된 원본.
    var skipped: [URL] = []
    var failures: [OperationFailure] = []
    /// 사용자가 `Esc`/"취소"로 중단한 경우. 이미 처리된 항목(`produced`)은 유지된다.
    var isCancelled: Bool = false

    var hasFailures: Bool { !failures.isEmpty }

    /// UI설계 §8 — 다중 작업 중 일부 실패 시 끝에 요약 1회.
    func summaryMessage(for kind: FileOperationKind) -> String? {
        guard !failures.isEmpty else {
            return isCancelled ? "\(kind.actionNoun) was stopped. Items already processed were kept." : nil
        }
        if failures.count == 1, let only = failures.first {
            return "\"\(only.url.lastPathComponent)\" couldn't be \(kind.completionVerb) — \(only.error.message)"
        }
        let names = failures.prefix(3).map { $0.url.lastPathComponent }.joined(separator: ", ")
        let suffix = failures.count > 3 ? " and \(failures.count - 3) more" : ""
        return "\(failures.count) items couldn't be \(kind.completionVerb) (\(names)\(suffix))"
    }
}
