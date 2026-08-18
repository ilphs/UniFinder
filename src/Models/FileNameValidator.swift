import Foundation

/// 이름 입력 검증 결과 (UI설계 §7.2).
enum FileNameValidationResult: Equatable {
    case valid
    /// 거부 — 필드 셰이크 + 툴팁으로 사유를 보여주고 편집을 유지한다.
    case invalid(reason: String)
    /// `.`으로 시작(숨김화) — 거부가 아니라 확인 알림 1회.
    case needsConfirmation(reason: String)
}

/// 이름 변경/새 폴더 입력 규칙 (UI설계 §7.2).
///
/// **순수 함수로 분리한 이유**: 실제 편집은 `NSTableView` 셀 재사용 상태가 얽힌 AppKit
/// 경로(`InlineNameEditor`)에서 일어나므로, 규칙 자체는 뷰 계층과 무관하게 결정적으로
/// 검증할 수 있어야 한다.
enum FileNameValidator {

    /// APFS 파일명 상한.
    static let maxNameBytes = 255

    /// - Parameters:
    ///   - existingNames: 같은 폴더 안의 기존 이름들 (대소문자 비구분으로 비교)
    ///   - excludedName: 중복 판정에서 제외할 이름 — **자기 자신**.
    ///     APFS는 기본이 대소문자 비구분이라 이 제외가 없으면 `abc` → `ABC` 같은
    ///     대소문자만 바꾸는 rename이 항상 "중복"으로 실패한다 (m2-impl T0).
    static func validate(
        _ name: String,
        existingNames: Set<String>,
        excluding excludedName: String? = nil
    ) -> FileNameValidationResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .invalid(reason: "Enter a name.")
        }
        guard !trimmed.contains("/") else {
            return .invalid(reason: "The name can't contain \"/\".")
        }
        guard !trimmed.contains(":") else {
            return .invalid(reason: "The name can't contain \":\".")
        }
        guard trimmed != ".", trimmed != ".." else {
            return .invalid(reason: "That name can't be used.")
        }
        guard trimmed.utf8.count <= maxNameBytes else {
            return .invalid(reason: "The name is too long (maximum \(maxNameBytes) bytes).")
        }

        let excluded = excludedName?.lowercased()
        let taken = existingNames
            .map { $0.lowercased() }
            .filter { $0 != excluded }
        guard !taken.contains(trimmed.lowercased()) else {
            return .invalid(reason: "An item with that name already exists.")
        }

        if trimmed.hasPrefix(".") {
            return .needsConfirmation(reason: "Names that begin with a dot are hidden items.")
        }
        return .valid
    }
}
