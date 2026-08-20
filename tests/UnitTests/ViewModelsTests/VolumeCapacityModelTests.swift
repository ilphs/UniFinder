import XCTest
@testable import UniFinder

/// 상태바 우측 여유 공간 표시 — `VolumeCapacityModel` (UI설계 §5, 2026-08-20).
///
/// 실제 디스크 상태에 의존하면 개발 머신마다 값이 달라 단언을 쓸 수 없다 —
/// 볼륨 특정(`.volumeURLKey`)과 용량 조회를 모두 주입한다.
@MainActor
final class VolumeCapacityModelTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private func makeModel(
        volumes: [String: URL],
        capacities: [String: VolumeService.Capacity],
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSinceReferenceDate: 1_000) },
        readCounter: (@Sendable (URL) -> Void)? = nil
    ) -> VolumeCapacityModel {
        VolumeCapacityModel(
            locator: { directory in volumes[directory.standardizedFileURL.path] },
            capacityReader: { volume in
                readCounter?(volume)
                return capacities[volume.standardizedFileURL.path]
            },
            now: now
        )
    }

    /// 조회 횟수 기록 — `capacityReader`가 백그라운드에서 불리므로 잠금을 건다.
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func record(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            urls.append(url)
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return urls.count
        }
    }

    // MARK: - 표시 문구

    func testDisplayText_showsFreeSpace() {
        XCTAssertEqual(VolumeCapacityModel.displayText(freeBytes: 312_400_000_000), "312.4 GB free")
    }

    /// 조회 실패는 `--`가 아니라 **표시 없음**이다 — 한 줄 상태바에서 `--`는 정보를 주지 않는다
    /// (용량 창은 표라서 행을 남기고 `--`를 쓴다 — 규칙이 다른 이유가 문서화된 차이다).
    func testDisplayText_isNilWhenCapacityUnknown() {
        XCTAssertNil(VolumeCapacityModel.displayText(freeBytes: nil))
    }

    // MARK: - 갱신 정책 (D9의 예외)

    func testShouldRead_explicitReasonAlwaysReads() {
        // ⌘R·조작 완료는 "지금 값을 보여달라"는 요청이라 스로틀을 통과한다.
        XCTAssertTrue(VolumeCapacityModel.shouldReadCapacity(
            previousVolume: url("/"),
            resolvedVolume: url("/"),
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            now: Date(timeIntervalSinceReferenceDate: 1_000),
            reason: .explicit
        ))
    }

    func testShouldRead_volumeChangedReadsImmediately() {
        // 다른 디스크의 숫자를 그대로 보여주는 것은 스로틀보다 나쁜 오답이다.
        XCTAssertTrue(VolumeCapacityModel.shouldReadCapacity(
            previousVolume: url("/"),
            resolvedVolume: url("/Volumes/USB"),
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            now: Date(timeIntervalSinceReferenceDate: 1_000),
            reason: .navigation
        ))
    }

    func testShouldRead_sameVolumeWithinStaleInterval_isThrottled() {
        XCTAssertFalse(VolumeCapacityModel.shouldReadCapacity(
            previousVolume: url("/"),
            resolvedVolume: url("/"),
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            now: Date(timeIntervalSinceReferenceDate: 1_000 + VolumeCapacityModel.staleInterval - 1),
            reason: .navigation
        ))
    }

    func testShouldRead_sameVolumeAfterStaleInterval_readsAgain() {
        XCTAssertTrue(VolumeCapacityModel.shouldReadCapacity(
            previousVolume: url("/"),
            resolvedVolume: url("/"),
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            now: Date(timeIntervalSinceReferenceDate: 1_000 + VolumeCapacityModel.staleInterval),
            reason: .navigation
        ))
    }

    /// 표기 차이(후행 슬래시)로 "볼륨이 바뀌었다"고 오판하면 스로틀이 통째로 무력화된다.
    func testShouldRead_volumeComparisonIgnoresPathNotation() {
        XCTAssertFalse(VolumeCapacityModel.shouldReadCapacity(
            previousVolume: URL(fileURLWithPath: "/Volumes/USB", isDirectory: false),
            resolvedVolume: URL(fileURLWithPath: "/Volumes/USB", isDirectory: true),
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            now: Date(timeIntervalSinceReferenceDate: 1_001),
            reason: .navigation
        ))
    }

    // MARK: - 갱신 흐름

    func testUpdate_readsCapacityForTheVolumeContainingTheDirectory() async {
        let model = makeModel(
            volumes: ["/Users/someone/Documents": url("/")],
            capacities: ["/": .init(total: 1_000, available: 400)]
        )

        model.update(for: url("/Users/someone/Documents"), reason: .navigation)
        await model.waitForUpdate()

        XCTAssertEqual(model.volumeURL?.path, "/")
        XCTAssertEqual(model.capacity?.available, 400)
        XCTAssertEqual(model.displayText, VolumeCapacityModel.displayText(freeBytes: 400))
    }

    /// 같은 볼륨 안에서 폴더를 훑는 동안 볼륨을 반복 stat하지 않는다.
    func testUpdate_sameVolumeNavigation_doesNotReadAgainWithinStaleInterval() async {
        let counter = ReadCounter()
        let model = makeModel(
            volumes: ["/a": url("/"), "/b": url("/")],
            capacities: ["/": .init(total: 1_000, available: 400)],
            readCounter: { counter.record($0) }
        )

        model.update(for: url("/a"), reason: .navigation)
        await model.waitForUpdate()
        model.update(for: url("/b"), reason: .navigation)
        await model.waitForUpdate()

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(model.capacity?.available, 400, "스로틀은 표시 값을 지워버리면 안 된다")
    }

    func testUpdate_volumeChange_readsImmediatelyEvenWithinStaleInterval() async {
        let counter = ReadCounter()
        let model = makeModel(
            volumes: ["/a": url("/"), "/Volumes/USB/photos": url("/Volumes/USB")],
            capacities: [
                "/": .init(total: 1_000, available: 400),
                "/Volumes/USB": .init(total: 500, available: 120),
            ],
            readCounter: { counter.record($0) }
        )

        model.update(for: url("/a"), reason: .navigation)
        await model.waitForUpdate()
        model.update(for: url("/Volumes/USB/photos"), reason: .navigation)
        await model.waitForUpdate()

        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(model.volumeURL?.path, "/Volumes/USB")
        XCTAssertEqual(model.capacity?.available, 120)
    }

    func testUpdate_explicitReason_bypassesThrottle() async {
        let counter = ReadCounter()
        let model = makeModel(
            volumes: ["/a": url("/")],
            capacities: ["/": .init(total: 1_000, available: 400)],
            readCounter: { counter.record($0) }
        )

        model.update(for: url("/a"), reason: .navigation)
        await model.waitForUpdate()
        model.update(for: url("/a"), reason: .explicit)
        await model.waitForUpdate()

        XCTAssertEqual(counter.count, 2)
    }

    /// 볼륨을 특정할 수 없으면 **낡은 숫자를 남기지 않는다** — 다른 디스크의 값일 수 있다.
    func testUpdate_unresolvableVolume_clearsDisplay() async {
        let model = makeModel(
            volumes: ["/a": url("/")],
            capacities: ["/": .init(total: 1_000, available: 400)]
        )

        model.update(for: url("/a"), reason: .navigation)
        await model.waitForUpdate()
        XCTAssertNotNil(model.displayText)

        model.update(for: url("/gone"), reason: .navigation)
        await model.waitForUpdate()

        XCTAssertNil(model.volumeURL)
        XCTAssertNil(model.displayText)
    }

    /// 용량 조회 실패도 시각을 남긴다 — 응답 없는 마운트를 매 이동마다 다시 두드리지 않기 위함이다.
    func testUpdate_capacityReadFailure_hidesTextButRecordsAttempt() async {
        let model = makeModel(volumes: ["/a": url("/Volumes/Broken")], capacities: [:])

        model.update(for: url("/a"), reason: .navigation)
        await model.waitForUpdate()

        XCTAssertEqual(model.volumeURL?.path, "/Volumes/Broken")
        XCTAssertNil(model.displayText)
        XCTAssertNotNil(model.updatedAt)
    }
}
