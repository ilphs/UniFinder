import XCTest
@testable import UniFinder

/// 상태바 용량 표시의 **배선** — 어느 시점에 갱신되는가 (UI설계 §5, 2026-08-20).
///
/// 정책 자체(스로틀·표시 문구)는 `VolumeCapacityModelTests`가 본다. 여기서는
/// `AppModel`이 정한 갱신 시점만 고정한다: 폴더 이동은 `.navigation`, `⌘R`은 `.explicit`.
@MainActor
final class StatusBarCapacityTests: TempDirectoryTestCase {

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

    /// `testRoot`를 볼륨 루트처럼 취급하는 가짜 특정기 — 하위 폴더는 모두 같은 볼륨이다.
    private func makeCapacityModel(counter: ReadCounter, available: Int64 = 4_096) -> VolumeCapacityModel {
        let root = testRoot!
        return VolumeCapacityModel(
            locator: { _ in VolumeService.canonicalDirectoryURL(root) },
            capacityReader: { url in
                counter.record(url)
                return .init(total: 8_192, available: available)
            }
        )
    }

    private func makeModel(capacity: VolumeCapacityModel) -> AppModel {
        AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "StatusBarCapacity-\(UUID().uuidString)")!),
            volumeCapacity: capacity,
            startURL: testRoot
        )
    }

    func testNavigation_updatesCapacityForTheNewFolder() async throws {
        let counter = ReadCounter()
        let capacity = makeCapacityModel(counter: counter)
        let model = makeModel(capacity: capacity)
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Photos")

        model.navigate(to: folder)
        await capacity.waitForUpdate()

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(model.volumeCapacity.displayText, VolumeCapacityModel.displayText(freeBytes: 4_096))
    }

    /// 같은 볼륨 안의 연속 이동은 스로틀에 걸린다 — 폴더를 훑는 내내 볼륨을 stat하지 않는다.
    func testConsecutiveNavigationWithinSameVolume_isThrottled() async throws {
        let counter = ReadCounter()
        let capacity = makeCapacityModel(counter: counter)
        let model = makeModel(capacity: capacity)
        let first = try Fixture.makeDirectory(in: testRoot, name: "A")
        let second = try Fixture.makeDirectory(in: testRoot, name: "B")

        model.navigate(to: first)
        await capacity.waitForUpdate()
        model.navigate(to: second)
        await capacity.waitForUpdate()

        XCTAssertEqual(counter.count, 1)
    }

    /// `⌘R`은 사용자가 변화를 기대하는 시점이므로 스로틀을 통과해야 한다.
    func testRefresh_bypassesThrottle() async throws {
        let counter = ReadCounter()
        let capacity = makeCapacityModel(counter: counter)
        let model = makeModel(capacity: capacity)
        let folder = try Fixture.makeDirectory(in: testRoot, name: "Photos")

        model.navigate(to: folder)
        await capacity.waitForUpdate()
        model.refresh()
        await capacity.waitForUpdate()

        XCTAssertEqual(counter.count, 2)
    }
}
