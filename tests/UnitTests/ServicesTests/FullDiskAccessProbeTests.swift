import XCTest
@testable import UniFinder

/// FDA 권한 프로브 판정 로직 단위 테스트 (m3-impl T5 / B22 수용 기준).
///
/// 핵심 요구: **"경로 없음"을 "미허용"으로 오판하지 않는다.** `~/Library/Mail`은 Mail을 쓰지 않는
/// 사용자에게 존재하지 않아 `NSFileReadNoSuchFileError`가 나므로, 이를 거부로 접으면 오탐이다.
/// 실제 TCC 권한 상태에 의존하지 않도록 `ProtectedPathProbing`을 주입해 판정만 고정한다.
final class FullDiskAccessProbeTests: TempDirectoryTestCase {

    // MARK: - 3상태 판정 (B22)

    func testEvaluate_allCandidatesMissing_isUndetermined_notDenied() {
        let probe = MockProtectedPathProbe([.missing, .missing, .missing])

        XCTAssertEqual(
            probe.evaluateStatus(),
            .undetermined,
            "후보가 전부 '존재하지 않음'인데 미허용으로 단정하면 B22 오탐이다"
        )
    }

    func testEvaluate_missingThenDenied_isDenied() {
        let probe = MockProtectedPathProbe([.missing, .denied])

        XCTAssertEqual(probe.evaluateStatus(), .denied)
        XCTAssertEqual(probe.probedPaths.count, 2, "없는 후보에서 멈추지 않고 다음 후보를 시도해야 한다")
    }

    func testEvaluate_missingThenReadable_isGranted() {
        let probe = MockProtectedPathProbe([.missing, .readable])

        XCTAssertEqual(probe.evaluateStatus(), .granted)
    }

    func testEvaluate_deniedThenReadable_isGranted() {
        // 하나라도 실제로 읽혔으면 FDA는 허용된 것이다(다른 후보의 실패는 권한 문제가 아니다).
        let probe = MockProtectedPathProbe([.denied, .readable])

        XCTAssertEqual(probe.evaluateStatus(), .granted)
    }

    func testEvaluate_firstReadable_shortCircuits() {
        let probe = MockProtectedPathProbe([.readable, .denied, .denied])

        XCTAssertEqual(probe.evaluateStatus(), .granted)
        XCTAssertEqual(probe.probedPaths.count, 1, "확정된 뒤에는 추가 프로브를 하지 않는다")
    }

    func testEvaluate_inconclusiveOnly_isUndetermined() {
        let probe = MockProtectedPathProbe([.inconclusive, .missing, .inconclusive])

        XCTAssertEqual(probe.evaluateStatus(), .undetermined)
    }

    func testEvaluate_noCandidates_isUndetermined() {
        let probe = MockProtectedPathProbe([])

        XCTAssertEqual(probe.evaluateStatus(), .undetermined)
    }

    // MARK: - 에러 분류

    func testClassify_noSuchFileError_isMissing_notDenied() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))

        XCTAssertEqual(ProbeOutcome.classify(cocoa), .missing)
        XCTAssertEqual(ProbeOutcome.classify(posix), .missing)
    }

    func testClassify_noPermissionError_isDenied() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))

        XCTAssertEqual(ProbeOutcome.classify(cocoa), .denied)
        XCTAssertEqual(ProbeOutcome.classify(eacces), .denied)
        XCTAssertEqual(ProbeOutcome.classify(eperm), .denied)
    }

    func testClassify_unknownError_isInconclusive() {
        let error = NSError(domain: "com.unifinder.test", code: 42)

        XCTAssertEqual(ProbeOutcome.classify(error), .inconclusive)
    }

    func testClassify_underlyingError_isUnwrapped() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let wrapper = NSError(
            domain: "com.unifinder.test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        XCTAssertEqual(ProbeOutcome.classify(wrapper), .denied)
    }

    // MARK: - 실제 파일시스템 프로브 (임시 디렉토리 격리)

    func testProbe_existingDirectory_isReadable() {
        let probe = FullDiskAccessProbe(candidates: [ProtectedPath(url: testRoot, kind: .directory)])

        XCTAssertEqual(probe.probe(probe.candidates[0]), .readable)
        XCTAssertEqual(probe.evaluateStatus(), .granted)
    }

    func testProbe_nonexistentPath_isMissing_soStatusIsUndetermined() {
        let ghost = testRoot.appendingPathComponent("존재하지-않는-폴더", isDirectory: true)
        let probe = FullDiskAccessProbe(candidates: [ProtectedPath(url: ghost, kind: .directory)])

        XCTAssertEqual(probe.probe(probe.candidates[0]), .missing)
        XCTAssertEqual(
            probe.evaluateStatus(),
            .undetermined,
            "존재하지 않는 프로브 경로를 미허용으로 판정하면 안 된다(B22)"
        )
    }

    func testProbe_nonexistentFile_isMissing() {
        let ghost = testRoot.appendingPathComponent("없는파일.db", isDirectory: false)
        let probe = FullDiskAccessProbe(candidates: [ProtectedPath(url: ghost, kind: .file)])

        XCTAssertEqual(probe.probe(probe.candidates[0]), .missing)
    }

    func testProbe_unreadableDirectory_isDenied() throws {
        // root 권한으로 테스트를 돌리면 chmod 000도 읽히므로 그 경우는 건너뛴다.
        try XCTSkipIf(getuid() == 0, "root로 실행 중 — 권한 거부를 재현할 수 없다")

        let (locked, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "locked")
        defer { restore() }

        let probe = FullDiskAccessProbe(candidates: [ProtectedPath(url: locked, kind: .directory)])

        XCTAssertEqual(probe.probe(probe.candidates[0]), .denied)
        XCTAssertEqual(probe.evaluateStatus(), .denied)
    }

    func testProbe_missingThenUnreadable_isDenied() throws {
        try XCTSkipIf(getuid() == 0, "root로 실행 중 — 권한 거부를 재현할 수 없다")

        let ghost = testRoot.appendingPathComponent("없음", isDirectory: true)
        let (locked, restore) = try Fixture.makeInaccessibleDirectory(in: testRoot, name: "locked2")
        defer { restore() }

        let probe = FullDiskAccessProbe(candidates: [
            ProtectedPath(url: ghost, kind: .directory),
            ProtectedPath(url: locked, kind: .directory),
        ])

        XCTAssertEqual(probe.evaluateStatus(), .denied)
    }

    // MARK: - 기본 후보 구성

    func testDefaultCandidates_areHomeOrSystemProtectedPaths_andDoNotIncludePromptingFolders() {
        let paths = FullDiskAccessProbe.defaultCandidates.map(\.url.path)

        XCTAssertFalse(paths.isEmpty)
        // 데스크탑/다운로드/서류는 개별 TCC 프롬프트를 띄우므로 프로브로 쓰면 안 된다.
        for forbidden in ["/Desktop", "/Downloads", "/Documents"] {
            XCTAssertFalse(
                paths.contains { $0.hasSuffix(forbidden) },
                "프롬프트를 유발하는 폴더(\(forbidden))를 프로브 후보로 쓰면 안 된다"
            )
        }
        XCTAssertTrue(
            paths.contains { $0.hasSuffix("/Library/Mail") },
            "B22가 지목한 '없을 수 있는' 경로도 후보에 포함하되 판정 불가로 처리해야 한다"
        )
    }

    /// 실제 환경(FDA 허용 여부 불명)에서도 프로브가 크래시 없이 3상태 중 하나를 돌려주는지.
    func testDefaultProbe_returnsSomeStatus_withoutCrashing() {
        let status = FullDiskAccessProbe().evaluateStatus()

        XCTAssertTrue([.granted, .denied, .undetermined].contains(status))
    }
}
