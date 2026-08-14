import XCTest
@testable import UniFinder

/// `DirectoryModel` 단위 테스트.
/// 대상(T3 수용 기준 + architect B3): 로드 race(빠른 연속 이동 시 마지막 요청만 반영,
/// `MockDirectoryListing`으로 지연 주입), 200ms 스피너 임계, 에러 상태 전이.
@MainActor
final class DirectoryModelTests: XCTestCase {

    private let urlA = URL(fileURLWithPath: "/tmp/dirA")
    private let urlB = URL(fileURLWithPath: "/tmp/dirB")

    private func item(_ name: String) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: false,
            isHidden: false,
            isSymlink: false,
            size: 0,
            modifiedAt: Fixture.fixedDate(),
            typeDescription: "Text"
        )
    }

    /// 조건이 만족될 때까지 폴링한다. 내부 Task 스케줄링에 의존하는 비동기 상태 전이를
    /// 안정적으로 검증하기 위한 헬퍼(구현 세부에 결합하지 않음).
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        interval: UInt64 = 10_000_000, // 10ms
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    // MARK: - 성공 로드

    func testLoad_success_populatesItemsAndClearsLoadingAndError() async {
        let mock = MockDirectoryListing()
        await mock.configure(url: urlA, items: [item("a.txt"), item("b.txt")])
        let model = DirectoryModel(loader: mock)

        model.load(url: urlA)
        await waitUntil { !model.items.isEmpty }

        XCTAssertEqual(model.items.map(\.name).sorted(), ["a.txt", "b.txt"])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    // MARK: - 200ms 스피너 임계

    func testLoad_shortDelay_belowThreshold_neverShowsSpinner() async {
        let mock = MockDirectoryListing()
        await mock.configure(url: urlA, items: [item("a.txt")])
        await mock.hold(url: urlA)
        let model = DirectoryModel(loader: mock)

        model.load(url: urlA)

        // 스피너 임계(200ms)보다 훨씬 짧게(60ms) 지연 후 게이트를 연다.
        try? await Task.sleep(nanoseconds: 60_000_000)
        var observedLoading = false
        for _ in 0..<6 {
            if model.isLoading { observedLoading = true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await mock.openGate(for: urlA)
        await waitUntil { !model.items.isEmpty }

        XCTAssertFalse(observedLoading, "200ms 미만 로드는 스피너가 표시되면 안 됨")
    }

    func testLoad_longDelay_aboveThreshold_showsSpinnerThenClears() async {
        let mock = MockDirectoryListing()
        await mock.configure(url: urlA, items: [item("a.txt")])
        await mock.hold(url: urlA)
        let model = DirectoryModel(loader: mock)

        model.load(url: urlA)

        // 임계(200ms) 이후 시점(350ms)까지 대기하며 스피너가 뜨는지 확인.
        await waitUntil(timeout: 1.0) { model.isLoading }
        XCTAssertTrue(model.isLoading, "200ms를 초과하는 로드는 스피너가 표시되어야 함")

        await mock.openGate(for: urlA)
        await waitUntil { !model.isLoading }

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.items.map(\.name), ["a.txt"])
    }

    // MARK: - 에러 상태 전이

    func testLoad_accessDenied_setsErrorAndClearsLoading() async {
        let mock = MockDirectoryListing()
        await mock.configure(url: urlA, error: .accessDenied)
        let model = DirectoryModel(loader: mock)

        model.load(url: urlA)
        await waitUntil { model.error != nil }

        XCTAssertEqual(model.error, .accessDenied)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testLoad_afterError_successfulReloadClearsError() async {
        let mock = MockDirectoryListing()
        await mock.configure(url: urlA, error: .accessDenied)
        await mock.configure(url: urlB, items: [item("ok.txt")])
        let model = DirectoryModel(loader: mock)

        model.load(url: urlA)
        await waitUntil { model.error != nil }
        XCTAssertNotNil(model.error)

        model.load(url: urlB)
        await waitUntil { !model.items.isEmpty }

        XCTAssertNil(model.error)
        XCTAssertEqual(model.items.map(\.name), ["ok.txt"])
    }

    // MARK: - 로딩 중 정렬 변경 (code review 필수 수정 #5)

    /// **재현 시나리오**: `load`가 시작 시점의 descriptor를 캡처했기 때문에, 로딩 중 헤더를
    /// 클릭해 정렬을 바꾸면 `resortCurrentItems`는 `items.isEmpty`라 즉시 반환하고,
    /// 뒤늦게 도착한 로드 결과는 "옛 descriptor"로 정렬되어 사용자의 정렬 변경이 유실됐다.
    func testLoad_sortChangedWhileLoading_appliesLatestDescriptor() async {
        let mock = MockDirectoryListing()
        await mock.configure(url: urlA, items: [item("a.txt"), item("b.txt"), item("c.txt")])
        await mock.hold(url: urlA)

        let model = DirectoryModel(loader: mock) // 기본: 이름 오름차순
        model.load(url: urlA)

        // 로딩 중 헤더 클릭 → 이름 내림차순. 이 시점 items는 비어 있어 재정렬 대상이 없다.
        model.toggleSort(for: .name)
        XCTAssertFalse(model.sortDescriptor.ascending)
        XCTAssertTrue(model.items.isEmpty)

        await mock.openGate(for: urlA)
        await waitUntil { model.items.count == 3 }

        XCTAssertEqual(
            model.items.map(\.name), ["c.txt", "b.txt", "a.txt"],
            "로딩 중 변경된 정렬이 로드 결과에 반영되어야 함(옛 descriptor로 정렬되면 안 됨)"
        )
    }

    func testLoad_sortUnchangedDuringLoad_keepsInitialDescriptor() async {
        let mock = MockDirectoryListing()
        await mock.configure(url: urlA, items: [item("c.txt"), item("a.txt"), item("b.txt")])

        let model = DirectoryModel(loader: mock)
        model.load(url: urlA)
        await waitUntil { model.items.count == 3 }

        XCTAssertEqual(model.items.map(\.name), ["a.txt", "b.txt", "c.txt"])
    }

    // MARK: - Race: 빠른 연속 이동 시 마지막 요청만 반영

    func testLoad_rapidSuccessiveNavigation_onlyLastRequestWins() async {
        let mock = MockDirectoryListing()
        await mock.configure(url: urlA, items: [item("stale_from_A.txt")])
        await mock.configure(url: urlB, items: [item("fresh_from_B.txt")])
        // A는 게이트로 붙잡아 B보다 늦게 "도착"하도록 강제한다.
        await mock.hold(url: urlA)

        let model = DirectoryModel(loader: mock)

        model.load(url: urlA)   // 진행 중, 아직 게이트에 막혀 완료되지 않음
        model.load(url: urlB)   // 즉시 이어서 이동 — 이전 요청은 취소/폐기되어야 함

        // B가 먼저(게이트 없이) 완료되어 반영됨을 기다린다.
        await waitUntil { !model.items.isEmpty }
        XCTAssertEqual(model.items.map(\.name), ["fresh_from_B.txt"])

        // 이제 A의 지연 응답을 뒤늦게 흘려보낸다 — 정상적으로 취소되었다면 결과에
        // 반영되지 않아야 한다("마지막 요청만 반영").
        await mock.openGate(for: urlA)
        try? await Task.sleep(nanoseconds: 100_000_000) // A의 완료를 처리할 시간을 준다

        XCTAssertEqual(
            model.items.map(\.name), ["fresh_from_B.txt"],
            "먼저 시작했지만 늦게 도착한 A의 결과가 B를 덮어쓰면 안 됨"
        )
        XCTAssertNil(model.error, "취소된 이전 요청의 결과/에러가 현재 상태에 반영되면 안 됨")
    }

    func testLoad_rapidTripleNavigation_onlyFinalTargetReflected() async {
        let urlC = URL(fileURLWithPath: "/tmp/dirC")
        let mock = MockDirectoryListing()
        await mock.configure(url: urlA, items: [item("A.txt")])
        await mock.configure(url: urlB, items: [item("B.txt")])
        await mock.configure(url: urlC, items: [item("C.txt")])
        await mock.hold(url: urlA)
        await mock.hold(url: urlB)

        let model = DirectoryModel(loader: mock)
        model.load(url: urlA)
        model.load(url: urlB)
        model.load(url: urlC)

        await waitUntil { !model.items.isEmpty }
        XCTAssertEqual(model.items.map(\.name), ["C.txt"])

        await mock.openGate(for: urlA)
        await mock.openGate(for: urlB)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.items.map(\.name), ["C.txt"], "A/B의 뒤늦은 응답이 C를 덮어쓰면 안 됨")
    }
}
