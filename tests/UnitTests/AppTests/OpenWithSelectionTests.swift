import XCTest
@testable import UniFinder

/// Open With의 **대상 범위와 실패 보고** (reviewer minor #6·#7).
///
/// 검증하는 계약 2가지:
/// 1. 여는 대상은 **선택 전체**다(Finder와 같은 규칙). `Other…` 경로도 마찬가지다.
/// 2. 실행 실패는 **삼키지 않는다** — 상태바 문구(`transientMessage`)로 사용자에게 도달한다.
///    `NSWorkspace.open`은 실패를 completion handler로만 알리므로, 그 값을 버리면
///    사용자는 "눌렀는데 아무 일도 안 일어나는" 화면만 본다.
@MainActor
final class OpenWithSelectionTests: TempDirectoryTestCase {

    /// 실행 기록 — completion handler가 임의 스레드에서 불릴 수 있어 잠금을 건다.
    final class LaunchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [([URL], URL)] = []

        func record(_ files: [URL], _ application: URL) {
            lock.lock(); defer { lock.unlock() }
            calls.append((files, application))
        }

        var all: [(files: [URL], application: URL)] {
            lock.lock(); defer { lock.unlock() }
            return calls.map { (files: $0.0, application: $0.1) }
        }
    }

    private struct LaunchFailure: LocalizedError {
        var errorDescription: String? { "the application is damaged" }
    }

    private let preview = URL(fileURLWithPath: "/Applications/Preview.app")

    private func makeModel(recorder: LaunchRecorder, failure: Error? = nil) throws -> AppModel {
        let model = AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "OpenWithSelection-\(UUID().uuidString)")!),
            operations: FileOperations(homeDirectory: testRoot),
            startURL: testRoot
        )
        model.openWithService = OpenWithService(
            candidatesProvider: { _ in [] },
            defaultApplicationProvider: { _ in nil },
            contentTypeProvider: { _ in nil },
            launcher: { files, application, completion in
                recorder.record(files, application)
                completion(failure)
            },
            fileDefaultSetter: { _, _ in XCTFail("한 번 열기가 기본 앱을 바꾸면 안 된다") },
            contentTypeDefaultSetter: { _, _ in XCTFail("한 번 열기가 시스템 기본값을 바꾸면 안 된다") }
        )
        return model
    }

    // MARK: - 대상 범위

    func testOpenWith_passesEverySelectedFileToTheLauncher() throws {
        let recorder = LaunchRecorder()
        let model = try makeModel(recorder: recorder)
        let files = [
            try Fixture.makeFile(in: testRoot, name: "a.pdf"),
            try Fixture.makeFile(in: testRoot, name: "b.pdf"),
            try Fixture.makeFile(in: testRoot, name: "c.pdf"),
        ]

        model.openWith(files, application: preview)

        XCTAssertEqual(recorder.all.count, 1, "파일마다 따로 열면 앱이 여러 번 뜬다 — 한 번에 넘겨야 한다")
        XCTAssertEqual(
            recorder.all.first?.files.map(\.lastPathComponent), ["a.pdf", "b.pdf", "c.pdf"],
            "3개를 선택했는데 전부 열리지 않았다"
        )
    }

    func testOpenWith_emptySelectionDoesNothing() throws {
        let recorder = LaunchRecorder()
        let model = try makeModel(recorder: recorder)

        model.openWith([], application: preview)

        XCTAssertTrue(recorder.all.isEmpty)
    }

    /// `Other…`도 같은 규칙 — 앱을 직접 고르는 경로에서만 대상이 1개로 줄면 안 된다.
    func testChooseApplicationAndOpen_passesEverySelectedFile() throws {
        let recorder = LaunchRecorder()
        let model = try makeModel(recorder: recorder)
        model.applicationChooser = { URL(fileURLWithPath: "/Applications/Preview.app") }
        let files = [
            try Fixture.makeFile(in: testRoot, name: "x.txt"),
            try Fixture.makeFile(in: testRoot, name: "y.txt"),
        ]

        model.chooseApplicationAndOpen(files)

        XCTAssertEqual(recorder.all.first?.files.map(\.lastPathComponent), ["x.txt", "y.txt"])
    }

    /// 앱 선택을 취소하면 **아무 일도 하지 않는다**.
    func testChooseApplicationAndOpen_cancelledChooserOpensNothing() throws {
        let recorder = LaunchRecorder()
        let model = try makeModel(recorder: recorder)
        model.applicationChooser = { nil }

        model.chooseApplicationAndOpen([try Fixture.makeFile(in: testRoot, name: "x.txt")])

        XCTAssertTrue(recorder.all.isEmpty)
    }

    // MARK: - 실패 보고

    func testOpenWith_launchFailureReachesTheStatusBar() async throws {
        let recorder = LaunchRecorder()
        let model = try makeModel(recorder: recorder, failure: LaunchFailure())
        let file = try Fixture.makeFile(in: testRoot, name: "a.pdf")

        model.openWith([file], application: preview)
        await waitUntil { model.transientMessage != nil }

        let message = try XCTUnwrap(model.transientMessage, "실행 실패가 조용히 삼켜졌다")
        XCTAssertTrue(message.contains("a.pdf"), message)
        XCTAssertTrue(message.contains("Preview"), message)
        XCTAssertTrue(message.contains("the application is damaged"), "실패 사유가 문구에 없다: \(message)")
    }

    /// 성공한 실행은 **아무 말도 하지 않는다** — 잘 된 조작에 메시지를 띄우면 상태바가 소음이 된다.
    func testOpenWith_successShowsNoMessage() async throws {
        let recorder = LaunchRecorder()
        let model = try makeModel(recorder: recorder)
        let file = try Fixture.makeFile(in: testRoot, name: "a.pdf")

        model.openWith([file], application: preview)
        // 실패 경로가 있었다면 여기서 메시지가 잡힌다(짧은 유예 뒤 확인).
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(model.transientMessage)
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
