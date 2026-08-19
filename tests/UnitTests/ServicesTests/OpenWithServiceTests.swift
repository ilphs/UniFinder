import UniformTypeIdentifiers
import XCTest
@testable import UniFinder

/// Open With / 기본 앱 지정 (후속 T4·T7 / UI설계 §7.8).
///
/// **실제 시스템 설정을 절대 바꾸지 않는다.** 이 테스트가 진짜 `NSWorkspace.setDefaultApplication`을
/// 부르면 테스트를 돌린 사람의 PDF 기본 앱이 바뀐다 — 그런 테스트는 존재해서는 안 된다.
/// 모든 LaunchServices 호출은 mock으로 대체하고, "무엇을 어떤 인자로 불렀는가"만 검증한다.
@MainActor
final class OpenWithServiceTests: TempDirectoryTestCase {

    /// 기본 앱 지정 호출 기록.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var fileCalls: [(application: URL, file: URL)] = []
        private(set) var typeCalls: [(application: URL, type: UTType)] = []

        func recordFile(_ application: URL, _ file: URL) {
            lock.lock(); defer { lock.unlock() }
            fileCalls.append((application, file))
        }

        func recordType(_ application: URL, _ type: UTType) {
            lock.lock(); defer { lock.unlock() }
            typeCalls.append((application, type))
        }

        var totalCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return fileCalls.count + typeCalls.count
        }
    }

    /// 실제 파일이어야 한다 — `ItemInfoModel.load()`가 읽지 못하면 팝업 후보가 채워지지 않아
    /// "이전 선택으로 복귀" 같은 계약을 검증할 수 없다.
    private var file: URL!
    private let preview = URL(fileURLWithPath: "/Applications/Preview.app")
    private let acrobat = URL(fileURLWithPath: "/Applications/Acrobat.app")
    /// 연타 시나리오에서 "세 번째 선택"으로 쓰는 후보.
    private let other = URL(fileURLWithPath: "/Applications/TextEdit.app")

    override func setUpWithError() throws {
        try super.setUpWithError()
        let created = try Fixture.makeFile(in: testRoot, name: "report.pdf", sizeBytes: 64)
        // `setUpWithError`는 nonisolated지만 XCTest는 메인 스레드에서 부른다.
        MainActor.assumeIsolated { file = created }
    }

    private func makeService(
        recorder: Recorder,
        candidates: [URL]? = nil,
        defaultApplication: URL? = nil,
        contentType: UTType? = .pdf,
        fileSetterError: Error? = nil,
        typeSetterError: Error? = nil
    ) -> OpenWithService {
        // MainActor 격리 프로퍼티를 `@Sendable` 클로저 안에서 읽지 않도록 지역 상수로 받아 둔다.
        let fallbackCandidates = candidates ?? [preview, acrobat]
        return OpenWithService(
            candidatesProvider: { _ in fallbackCandidates },
            defaultApplicationProvider: { _ in defaultApplication },
            displayNameProvider: { $0.deletingPathExtension().lastPathComponent },
            contentTypeProvider: { _ in contentType },
            launcher: { _, _, _ in },
            fileDefaultSetter: { application, file in
                if let fileSetterError { throw fileSetterError }
                recorder.recordFile(application, file)
            },
            contentTypeDefaultSetter: { application, type in
                if let typeSetterError { throw typeSetterError }
                recorder.recordType(application, type)
            }
        )
    }

    private func makeModel(service: OpenWithService) -> ItemInfoModel {
        ItemInfoModel(target: InfoTarget(url: file), openWithService: service)
    }

    // MARK: - 후보 목록

    func testApplications_putsDefaultFirstWithoutDuplicating() {
        let service = makeService(recorder: Recorder(), defaultApplication: acrobat)

        let options = service.applications(for: file)

        XCTAssertEqual(options.map(\.name), ["Acrobat", "Preview"], "기본 앱이 맨 앞이어야 한다")
        XCTAssertEqual(options.map(\.isDefault), [true, false])
        XCTAssertEqual(options.filter { $0.url == acrobat }.count, 1, "기본 앱이 후보에도 있으면 중복으로 뜬다")
    }

    func testApplications_noCandidatesYieldsEmptyList() {
        let service = makeService(recorder: Recorder(), candidates: [], defaultApplication: nil)

        XCTAssertTrue(service.applications(for: file).isEmpty)
    }

    // MARK: - 파일 1개 기본 앱 (확인 없음)

    func testSelectApplication_setsFileDefaultWithExactArguments() async {
        let recorder = Recorder()
        let model = makeModel(service: makeService(recorder: recorder, defaultApplication: preview))
        model.load()
        await model.waitForLoad()

        model.selectApplication(acrobat)
        await Task.yield()
        await waitUntil { recorder.fileCalls.count == 1 }

        XCTAssertEqual(recorder.fileCalls.first?.application, acrobat)
        XCTAssertEqual(recorder.fileCalls.first?.file.path, file.path)
        XCTAssertTrue(recorder.typeCalls.isEmpty, "팝업 선택이 UTType 전체를 바꾸면 안 된다 — 그건 Change All…의 일이다")
    }

    /// 실패하면 사유를 띄우고 선택을 **이전 값으로 되돌린다**(UI설계 §7.8).
    func testSelectApplication_failureRestoresPreviousSelection() async {
        struct Failure: Error {}
        let recorder = Recorder()
        let service = makeService(recorder: recorder, defaultApplication: preview, fileSetterError: Failure())
        let model = makeModel(service: service)
        model.load()
        await model.waitForLoad()
        XCTAssertEqual(model.selectedApplication, preview)

        model.selectApplication(acrobat)
        await waitUntil { model.applicationErrorMessage != nil }

        XCTAssertEqual(
            model.selectedApplication, preview,
            "실패했는데 팝업만 바뀌어 있으면 사용자는 기본 앱이 바뀐 줄 안다"
        )
        XCTAssertNotNil(model.applicationErrorMessage)
    }

    /// 성공하면 `(default)` 표기도 **고른 앱으로 옮겨간다** — 선택과 표기가 어긋나면
    /// 사용자는 무엇이 기본 앱인지 화면에서 읽을 수 없다.
    func testSelectApplication_successMovesTheDefaultFlag() async {
        let recorder = Recorder()
        let model = makeModel(service: makeService(recorder: recorder, defaultApplication: preview))
        model.load()
        await model.waitForLoad()
        XCTAssertEqual(model.applications.first(where: \.isDefault)?.url, preview)

        model.selectApplication(acrobat)
        await waitUntil { recorder.fileCalls.count == 1 }

        XCTAssertEqual(model.selectedApplication, acrobat)
        XCTAssertEqual(model.applications.first(where: \.isDefault)?.url, acrobat)
        XCTAssertEqual(model.applications.filter(\.isDefault).count, 1, "기본 앱이 둘로 보이면 안 된다")
    }

    /// 실패하면 `isDefault` 플래그도 **함께** 되돌아온다(reviewer minor #5).
    func testSelectApplication_failureRestoresDefaultFlagToo() async {
        struct Failure: Error {}
        let service = makeService(recorder: Recorder(), defaultApplication: preview, fileSetterError: Failure())
        let model = makeModel(service: service)
        model.load()
        await model.waitForLoad()

        model.selectApplication(acrobat)
        await waitUntil { model.applicationErrorMessage != nil }

        XCTAssertEqual(model.selectedApplication, preview)
        XCTAssertEqual(
            model.applications.first(where: \.isDefault)?.url, preview,
            "선택만 되돌리고 표기를 두면 '선택은 Preview인데 default 표기는 Acrobat'이라는 화면이 남는다"
        )
    }

    /// **연타 회귀** (reviewer minor #5): 빠르게 두 번 고르면 Task가 둘 겹친다.
    /// 두 번째가 실패했을 때 되돌아갈 곳은 첫 번째의 **미확정** 값이 아니라
    /// 마지막으로 확정된 상태(= 로드 직후의 기본 앱)여야 한다.
    func testSelectApplication_rapidSecondSelectionRollsBackToLastConfirmedState() async {
        struct Failure: Error {}
        let service = makeService(recorder: Recorder(), defaultApplication: preview, fileSetterError: Failure())
        let model = makeModel(service: service)
        model.load()
        await model.waitForLoad()
        XCTAssertEqual(model.selectedApplication, preview)

        // 두 호출 모두 Task를 만들지만, 본문은 이 동기 구간이 끝난 뒤에야 돈다 — 실제 연타와 같은 상황.
        model.selectApplication(acrobat)
        model.selectApplication(other)
        await waitUntil { model.applicationErrorMessage != nil }
        // 이전 Task가 뒤늦게 상태를 건드리지 않는지 확인할 여유를 준다.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            model.selectedApplication, preview,
            "확정된 적 없는 중간 선택(Acrobat)으로 되돌아갔다 — 실제 기본 앱과 어긋난 표시다"
        )
        XCTAssertEqual(model.applications.first(where: \.isDefault)?.url, preview)
    }

    /// 성공 뒤에 실패하면 **성공했던 값**으로 되돌아온다(확정 상태가 갱신됐는지).
    func testSelectApplication_failureAfterSuccessRestoresTheSucceededSelection() async {
        struct Failure: Error {}
        let recorder = Recorder()
        let failNext = FailureSwitch()
        let service = OpenWithService(
            candidatesProvider: { _ in [self.preview, self.acrobat, self.other] },
            defaultApplicationProvider: { _ in self.preview },
            displayNameProvider: { $0.deletingPathExtension().lastPathComponent },
            contentTypeProvider: { _ in .pdf },
            launcher: { _, _, _ in },
            fileDefaultSetter: { application, file in
                if failNext.isOn { throw Failure() }
                recorder.recordFile(application, file)
            },
            contentTypeDefaultSetter: { _, _ in }
        )
        let model = makeModel(service: service)
        model.load()
        await model.waitForLoad()

        model.selectApplication(acrobat)
        await waitUntil { recorder.fileCalls.count == 1 }
        XCTAssertEqual(model.selectedApplication, acrobat)

        failNext.turnOn()
        model.selectApplication(other)
        await waitUntil { model.applicationErrorMessage != nil }

        XCTAssertEqual(model.selectedApplication, acrobat, "직전에 성공한 선택으로 돌아가야 한다")
        XCTAssertEqual(model.applications.first(where: \.isDefault)?.url, acrobat)
    }

    /// 스위치를 백그라운드 클로저에서 읽으므로 스레드 안전해야 한다.
    final class FailureSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isOn: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func turnOn() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }
    }

    // MARK: - Change All… (확인 필수)

    /// **취소하면 어떤 API도 부르지 않는다** — 이 파일의 가장 중요한 단언이다.
    func testChangeAll_cancelCallsNoAPI() async {
        let recorder = Recorder()
        let model = makeModel(service: makeService(recorder: recorder, defaultApplication: preview))
        model.load()
        await model.waitForLoad()

        model.requestChangeAll()
        XCTAssertTrue(model.isChangeAllConfirmationPresented, "확인 없이 바로 바뀌면 안 된다")

        model.cancelChangeAll()
        await Task.yield()

        XCTAssertFalse(model.isChangeAllConfirmationPresented)
        XCTAssertEqual(recorder.totalCalls, 0, "취소했는데 시스템 설정이 바뀌었다 — 되돌릴 방법을 안내할 수 없다")
    }

    func testChangeAll_confirmPassesExactApplicationAndContentType() async {
        let recorder = Recorder()
        let model = makeModel(service: makeService(recorder: recorder, defaultApplication: preview))
        model.load()
        await model.waitForLoad()

        model.requestChangeAll()
        model.confirmChangeAll()
        await waitUntil { recorder.typeCalls.count == 1 }

        XCTAssertEqual(recorder.typeCalls.first?.application, preview)
        XCTAssertEqual(recorder.typeCalls.first?.type, .pdf)
        XCTAssertFalse(model.isChangeAllConfirmationPresented)
    }

    func testChangeAll_failureShowsMessage() async {
        struct Failure: Error {}
        let recorder = Recorder()
        let service = makeService(recorder: recorder, defaultApplication: preview, typeSetterError: Failure())
        let model = makeModel(service: service)
        model.load()
        await model.waitForLoad()

        model.requestChangeAll()
        model.confirmChangeAll()
        await waitUntil { model.applicationErrorMessage != nil }

        XCTAssertNotNil(model.applicationErrorMessage)
    }

    /// UTType을 알 수 없으면 확인 창 자체를 띄우지 않는다(무엇에 적용되는지 말할 수 없으므로).
    func testChangeAll_withoutContentTypeDoesNotPresentConfirmation() async {
        let model = makeModel(service: makeService(recorder: Recorder(), defaultApplication: preview, contentType: nil))
        model.load()
        await model.waitForLoad()

        model.requestChangeAll()

        XCTAssertFalse(model.isChangeAllConfirmationPresented)
    }

    /// **뷰 렌더 경로에 디스크 stat을 두지 않는다** (reviewer minor #4).
    ///
    /// `changeAllConfirmationMessage`는 Get Info 창의 `body`에서 불린다. 예전에는 그 문구가
    /// computed `changeAllContentType`을 읽었고, 그 프로퍼티는 접근할 때마다
    /// `contentTypeProvider`(= `URL.resourceValues`, 디스크 stat)를 불렀다 —
    /// **렌더 한 번마다 stat 한 번**이고, 느린 볼륨에서는 그 stat이 메인 액터를 잡는다.
    func testChangeAllContentType_isReadOnceAtLoadNotOnEveryAccess() async {
        let counter = CallCounter()
        let service = OpenWithService(
            candidatesProvider: { _ in [self.preview] },
            defaultApplicationProvider: { _ in self.preview },
            displayNameProvider: { $0.deletingPathExtension().lastPathComponent },
            contentTypeProvider: { _ in
                counter.increment()
                return .pdf
            },
            launcher: { _, _, _ in },
            fileDefaultSetter: { _, _ in },
            contentTypeDefaultSetter: { _, _ in }
        )
        let model = makeModel(service: service)
        model.load()
        await model.waitForLoad()

        let afterLoad = counter.count
        XCTAssertEqual(afterLoad, 1, "로드에서 한 번만 읽어야 한다")

        // 뷰가 여러 번 그려지는 상황 — 문구와 프로퍼티를 반복해서 읽는다.
        for _ in 0..<20 {
            _ = model.changeAllConfirmationMessage
            _ = model.changeAllContentType
        }

        XCTAssertEqual(counter.count, afterLoad, "렌더마다 디스크를 다시 읽고 있다")
        XCTAssertEqual(model.changeAllContentType, .pdf, "저장된 값이 그대로 쓰여야 한다")
    }

    /// 조회 클로저가 백그라운드에서 불리므로 계수도 스레드 안전해야 한다.
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            value += 1
        }
    }

    /// 확인 문구가 "적용 범위"를 분명히 말하는지 (UI설계 §7.8).
    func testChangeAllConfirmationMessage_statesScope() async {
        let model = makeModel(service: makeService(recorder: Recorder(), defaultApplication: preview))
        model.load()
        await model.waitForLoad()

        let message = model.changeAllConfirmationMessage

        XCTAssertTrue(message.contains("Preview"), "어떤 앱으로 바뀌는지: \(message)")
        XCTAssertTrue(message.contains("every"), "전체에 적용된다는 사실이 문구에 없다: \(message)")
        XCTAssertTrue(message.contains("report.pdf"), "지금 파일만이 아니라는 대비가 없다: \(message)")
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
