import XCTest
@testable import UniFinder

/// **M2 백로그 회귀** — 대소문자만 바꾸는 rename의 임시 이름(staging) 복구 실패를 삼키던 결함.
///
/// 예전 구현은 되돌리기를 `try?`로 호출해서 복구 실패가 조용히 사라졌다. 그러면 항목은
/// `.unifinder-rename-<UUID>` 이름으로 디스크에 남는데 `DirectoryLoader`가 그 접두사를 열거
/// 단계에서 걸러내므로 **목록에도 보이지 않는다** — 사용자는 원래 rename 에러만 보고 파일이
/// 사라졌다고 판단한다(이 백로그 4건 중 유일한 "데이터 유실로 보이는" 시나리오).
///
/// 이동 연산을 주입받는 `FileOperations.renameChangingCaseOnly(_:to:staging:move:)` 본체로
/// 검증한다 — 복구 실패는 실 파일시스템에서 결정적으로 재현할 수 없기 때문이고,
/// 이 파일의 `uniqueURL(for:exists:)`가 이미 쓰고 있는 주입 패턴을 그대로 따른다.
final class FileOperationsRenameStagingTests: TempDirectoryTestCase {

    private let parent = URL(fileURLWithPath: "/tmp/unifinder-rename-staging")
    private var item: URL { parent.appendingPathComponent("readme.txt") }
    private var target: URL { parent.appendingPathComponent("README.txt") }
    private var staging: URL { parent.appendingPathComponent("\(FileOperations.renameStagingPrefix)fixed") }

    // MARK: - 복구 성공 (기존 동작 유지)

    /// 되돌리기에 성공한 경로는 **예전과 완전히 같아야 한다**: 원래 rename 에러를 그대로 보고한다.
    func testRenameCaseOnly_whenRecoverySucceeds_reportsOriginalErrorAndRestoresOriginalName() {
        var moves: [String] = []

        XCTAssertThrowsError(
            try FileOperations.renameChangingCaseOnly(item, to: target, staging: staging) { source, destination in
                moves.append("\(source.lastPathComponent)->\(destination.lastPathComponent)")
                if destination == self.target { throw FileOperationError.accessDenied }
            }
        ) { error in
            XCTAssertEqual(
                error as? FileOperationError, .accessDenied,
                "복구에 성공했으면 사용자에게는 원래 실패 사유만 보여야 한다"
            )
        }

        XCTAssertEqual(
            moves,
            [
                "readme.txt->\(staging.lastPathComponent)",
                "\(staging.lastPathComponent)->README.txt",
                "\(staging.lastPathComponent)->readme.txt",
            ],
            "실패 시 임시 이름을 원래 이름으로 되돌리는 순서가 유지되어야 한다"
        )
    }

    func testRenameCaseOnly_success_movesThroughStagingExactlyOnce() throws {
        var moves: [String] = []

        try FileOperations.renameChangingCaseOnly(item, to: target, staging: staging) { source, destination in
            moves.append("\(source.lastPathComponent)->\(destination.lastPathComponent)")
        }

        XCTAssertEqual(moves.count, 2, "성공 경로는 2단계(원본→임시→대상)여야 한다")
    }

    // MARK: - 복구 실패 (M2 백로그 본체)

    func testRenameCaseOnly_whenRecoveryAlsoFails_reportsStrandedStagingPath() {
        XCTAssertThrowsError(
            try FileOperations.renameChangingCaseOnly(item, to: target, staging: staging) { source, _ in
                // 임시 이름에서 나가는 이동은 전부 실패 = 되돌리기까지 실패한 상황
                if source == self.staging { throw FileOperationError.accessDenied }
            }
        ) { error in
            XCTAssertEqual(
                error as? FileOperationError,
                .renameStagingStranded(
                    stagedPath: staging.path,
                    cause: FileOperationError.accessDenied.message,
                    recoveryFailure: FileOperationError.accessDenied.message
                ),
                "복구 실패가 원래 에러에 흡수되면 사용자는 파일이 사라진 줄 안다"
            )
        }
    }

    /// 사용자 문구에 **실제로 남은 경로**가 드러나야 손으로 복구할 수 있다(목록에서는 걸러지는 이름이다).
    func testStrandedError_messageCarriesTheStagedPathSoUserCanRecoverManually() {
        let error = FileOperationError.renameStagingStranded(
            stagedPath: staging.path,
            cause: FileOperationError.nameExists.message,
            recoveryFailure: FileOperationError.accessDenied.message
        )

        XCTAssertTrue(error.message.contains(staging.path), "남은 경로가 없으면 사용자가 되돌릴 방법이 없다")
        XCTAssertTrue(error.message.contains(FileOperationError.accessDenied.message), "복구 실패 사유가 보여야 한다")
        XCTAssertFalse(
            error.message.contains(FileOperationError.sourceMissing.message),
            "'항목이 사라졌다'로 오인될 문구를 쓰면 안 된다"
        )
    }

    /// 보고 경로(`FileOperations.rename` catch → `report(_:kind:)`)와 어긋나지 않아야 한다:
    /// 도메인 에러는 `map`이 그대로 통과시키고, 실패 요약 문구에 남은 경로가 실려야 한다.
    func testStrandedError_survivesErrorMappingAndAppearsInFailureSummary() {
        let stranded = FileOperationError.renameStagingStranded(
            stagedPath: staging.path,
            cause: FileOperationError.accessDenied.message,
            recoveryFailure: FileOperationError.accessDenied.message
        )

        XCTAssertEqual(FileOperationError.map(stranded), stranded, "도메인 에러는 매핑에서 변형되면 안 된다")

        var result = OperationResult()
        result.failures = [OperationFailure(url: item, error: stranded)]
        let summary = result.summaryMessage(for: .rename)

        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains(staging.path) == true, "요약 문구까지 남은 경로가 전달되어야 한다")
    }

    // MARK: - 실 파일시스템 회귀 (정상 경로가 그대로인지)

    /// 리팩터링 후에도 대소문자 rename이 동작하고 임시 이름 아티팩트를 남기지 않아야 한다.
    func testRename_caseOnlyChange_onDisk_leavesNoStagingArtifact() async throws {
        let operations = FileOperations()
        let file = try Fixture.makeFile(in: testRoot, name: "readme.txt")

        let result = await operations.rename(item: file, to: "README.txt")

        XCTAssertTrue(result.failures.isEmpty, "대소문자만 다른 이름 변경이 실패함: \(result.failures)")
        XCTAssertEqual(result.produced.first?.lastPathComponent, "README.txt")

        let names = try FileManager.default.contentsOfDirectory(atPath: testRoot.path)
        XCTAssertFalse(
            names.contains { $0.hasPrefix(FileOperations.renameStagingPrefix) },
            "임시 이름이 남으면 목록에서 걸러져 사용자 눈에는 파일이 사라진 것으로 보인다"
        )
    }
}
