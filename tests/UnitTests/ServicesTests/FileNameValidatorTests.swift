import XCTest
@testable import UniFinder

/// 이름 변경/새 폴더 입력 검증 (m2-impl.md T5) 단위 테스트.
///
/// 인라인 편집(`FileNameCellView`)은 AppKit 뷰 재사용 상태를 다루므로 이 검증 로직 자체는
/// 순수 함수로 분리되어 있다고 가정한다(뷰 계층과 무관하게 결정적으로 테스트하기 위함).
///
/// **가정하는 프로덕션 API**:
/// ```swift
/// enum FileNameValidationResult: Equatable {
///     case valid
///     case invalid(reason: String)          // 빈 이름 / `/` / `:` / 중복
///     case needsConfirmation(reason: String) // `.`으로 시작 — 확인 알림 1회
/// }
/// enum FileNameValidator {
///     static func validate(
///         _ name: String,
///         existingNames: Set<String>,
///         excluding excludedName: String? = nil // 자기 자신(대소문자 rename 등) 제외
///     ) -> FileNameValidationResult
/// }
/// ```
final class FileNameValidatorTests: XCTestCase {

    // MARK: - 금지 이름 4종

    func testValidate_emptyName_isInvalid() {
        let result = FileNameValidator.validate("", existingNames: [])
        guard case .invalid = result else { return XCTFail("빈 이름이 거부되지 않음: \(result)") }
    }

    func testValidate_nameContainingSlash_isInvalid() {
        let result = FileNameValidator.validate("a/b", existingNames: [])
        guard case .invalid = result else { return XCTFail("'/' 포함 이름이 거부되지 않음: \(result)") }
    }

    func testValidate_nameContainingColon_isInvalid() {
        let result = FileNameValidator.validate("a:b", existingNames: [])
        guard case .invalid = result else { return XCTFail("':' 포함 이름이 거부되지 않음: \(result)") }
    }

    func testValidate_duplicateName_isInvalid() {
        let result = FileNameValidator.validate("existing.txt", existingNames: ["existing.txt"])
        guard case .invalid = result else { return XCTFail("중복 이름이 거부되지 않음: \(result)") }
    }

    func testValidate_duplicateName_caseInsensitiveMatch_isInvalid() {
        // APFS는 기본적으로 대소문자 비구분 — "Existing.txt"도 중복으로 취급되어야 한다.
        let result = FileNameValidator.validate("Existing.TXT", existingNames: ["existing.txt"])
        guard case .invalid = result else { return XCTFail("대소문자만 다른 중복이 거부되지 않음: \(result)") }
    }

    // MARK: - 자기 자신 제외 (대소문자만 바꾸는 rename)

    func testValidate_caseOnlyChangeOfOwnName_excludingSelf_isValid() {
        let result = FileNameValidator.validate(
            "Existing.txt",
            existingNames: ["existing.txt"],
            excluding: "existing.txt"
        )
        XCTAssertEqual(result, .valid, "자기 자신을 제외하지 않으면 대소문자만 바꾸는 rename이 항상 실패함(B3)")
    }

    // MARK: - `.` 시작 확인

    func testValidate_nameStartingWithDot_needsConfirmationNotOutrightInvalid() {
        let result = FileNameValidator.validate(".hidden", existingNames: [])
        guard case .needsConfirmation = result else {
            return XCTFail("'.' 시작 이름은 거부가 아니라 확인 알림이어야 함: \(result)")
        }
    }

    // MARK: - 정상 이름

    func testValidate_normalUniqueName_isValid() {
        let result = FileNameValidator.validate("new-name.txt", existingNames: ["other.txt"])
        XCTAssertEqual(result, .valid)
    }

    func testValidate_unicodeNameWithoutForbiddenCharacters_isValid() {
        let result = FileNameValidator.validate("한글 이름 📁", existingNames: [])
        XCTAssertEqual(result, .valid)
    }
}
