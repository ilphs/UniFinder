import SwiftUI
import XCTest
@testable import UniFinder

/// 디스크 용량 창 (후속 T8 / UI설계 §7.7 · D1 · D9).
///
/// 실제 디스크 상태에 의존하면 개발 머신마다 값이 달라 단언을 쓸 수 없다 —
/// 볼륨 목록과 용량 조회를 모두 주입한다.
@MainActor
final class DiskUsageModelTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private func makeModel(
        volumes: [URL],
        attributes: [String: VolumeService.VolumeAttributes] = [:],
        capacities: [String: DiskUsageModel.Capacity],
        now: Date = Date(timeIntervalSinceReferenceDate: 1_000_000)
    ) -> DiskUsageModel {
        let service = VolumeService(
            enumerator: { _, _ in volumes },
            attributeReader: { url in
                attributes[url.path] ?? .init(isLocal: true, isBrowsable: true, name: url.lastPathComponent)
            }
        )
        return DiskUsageModel(
            volumeService: service,
            capacityReader: { url in capacities[url.path] },
            now: { now }
        )
    }

    // MARK: - 목록 구성

    func testRefresh_listsLocalVolumesWithRootFirstThenAlphabetical() async {
        let model = makeModel(
            volumes: [url("/Volumes/Zeta"), url("/"), url("/Volumes/Alpha")],
            attributes: [
                "/": .init(isLocal: true, isBrowsable: true, name: "Macintosh HD"),
                "/Volumes/Zeta": .init(isLocal: true, isBrowsable: true, name: "Zeta"),
                "/Volumes/Alpha": .init(isLocal: true, isBrowsable: true, name: "Alpha"),
            ],
            capacities: [
                "/": .init(total: 1000, available: 400),
                "/Volumes/Zeta": .init(total: 200, available: 100),
                "/Volumes/Alpha": .init(total: 300, available: 150),
            ]
        )

        model.refresh()
        await model.waitForRefresh()

        XCTAssertEqual(model.volumes.map(\.name), ["Macintosh HD", "Alpha", "Zeta"])
        XCTAssertEqual(model.updatedAt, Date(timeIntervalSinceReferenceDate: 1_000_000))
    }

    /// 사이드바와 같은 `VolumeService`를 쓰므로 네트워크 볼륨은 여기서도 빠진다(설계서 §1.2).
    func testRefresh_excludesNetworkVolumes() async {
        let model = makeModel(
            volumes: [url("/"), url("/Volumes/NetShare")],
            attributes: [
                "/": .init(isLocal: true, isBrowsable: true, name: "Macintosh HD"),
                "/Volumes/NetShare": .init(isLocal: false, isBrowsable: true, name: "NetShare"),
            ],
            capacities: ["/": .init(total: 1000, available: 400)]
        )

        model.refresh()
        await model.waitForRefresh()

        XCTAssertEqual(model.volumes.map(\.name), ["Macintosh HD"])
    }

    // MARK: - 용량 계산 (D1)

    func testUsedBytes_isClampedAtZero() {
        // `forImportantUsage`는 정리 가능한 공간을 포함해 total보다 클 수 있다.
        let volume = DiskUsageModel.Volume(
            url: url("/"), name: "Macintosh HD", totalBytes: 100, availableBytes: 140
        )

        XCTAssertEqual(volume.usedBytes, 0, "음수 사용량은 사용자에게 아무 의미가 없다 — 0으로 클램프한다")
        XCTAssertEqual(volume.usedFraction, 0)
    }

    func testUsedFraction_andLowSpaceWarning() {
        let healthy = DiskUsageModel.Volume(url: url("/"), name: "HD", totalBytes: 1000, availableBytes: 400)
        XCTAssertEqual(healthy.usedBytes, 600)
        XCTAssertEqual(healthy.usedFraction, 0.6)
        XCTAssertFalse(healthy.isLowOnSpace)

        let tight = DiskUsageModel.Volume(url: url("/"), name: "HD", totalBytes: 1000, availableBytes: 90)
        XCTAssertTrue(tight.isLowOnSpace, "여유 10% 미만은 경고색이다(UI설계 §7.7)")
    }

    /// 조회 실패한 볼륨은 **행을 없애지 않고** 값만 `--`로 둔다 — 볼륨이 사라진 것처럼 보이면 안 된다.
    func testRefresh_unreadableVolumeKeepsRowWithPlaceholderValues() async {
        let model = makeModel(
            volumes: [url("/"), url("/Volumes/Broken")],
            capacities: ["/": .init(total: 1000, available: 400)]
        )

        model.refresh()
        await model.waitForRefresh()

        XCTAssertEqual(model.volumes.count, 2)
        let broken = model.volumes.first { $0.name == "Broken" }
        XCTAssertNil(broken?.totalBytes)
        XCTAssertNil(broken?.usedBytes)
        XCTAssertNil(broken?.usedFraction, "값이 없으면 막대를 그리지 않는다")
        XCTAssertEqual(DiskUsageWindow.capacityText(broken!), "--")
    }

    func testCapacityText_showsFreeTotalUsed() {
        let volume = DiskUsageModel.Volume(
            url: url("/"), name: "HD", totalBytes: 1_000_000_000, availableBytes: 250_000_000
        )

        let text = DiskUsageWindow.capacityText(volume)

        XCTAssertTrue(text.contains("free"))
        XCTAssertTrue(text.contains("total"))
        XCTAssertTrue(text.contains("used"))
    }

    // MARK: - 갱신 정책 (D9)

    /// 마운트/언마운트를 구독하지 않으므로, 값의 나이를 화면이 드러내야 한다.
    func testUpdatedText_showsClockTimeAfterRefresh() async {
        let model = makeModel(volumes: [url("/")], capacities: ["/": .init(total: 10, available: 5)])

        XCTAssertEqual(DiskUsageWindow.updatedText(model.updatedAt), "Not updated yet")

        model.refresh()
        await model.waitForRefresh()
        XCTAssertTrue(DiskUsageWindow.updatedText(model.updatedAt).hasPrefix("Updated "))
    }

    /// 갱신 지점이 `refresh()` 하나여야 한다 — 자동 갱신이 붙으면 사용자가 읽는 도중 숫자가 바뀐다.
    func testRefresh_isIdempotentAndDoesNotAccumulateRows() async {
        let model = makeModel(volumes: [url("/")], capacities: ["/": .init(total: 10, available: 5)])

        model.refresh()
        await model.waitForRefresh()
        model.refresh()
        await model.waitForRefresh()
        model.refresh()
        await model.waitForRefresh()

        XCTAssertEqual(model.volumes.count, 1)
    }

    // MARK: - 메인 액터 블로킹 금지 (reviewer major #4)

    /// **핵심 회귀**: 열거·용량 조회는 메인 액터 **밖**에서 돌아야 한다(설계서 §5 "메인 블로킹 0").
    ///
    /// 응답하지 않는 마운트가 하나라도 끼면 `resourceValues` 한 번이 수 초를 잡아먹는데,
    /// 메인 액터에서 부르면 그동안 앱 전체가 얼어붙는다. 조회 함수가 실제로 어느 스레드에서
    /// 불렸는지를 기록해 단언한다.
    func testRefresh_readsCapacitiesOffTheMainActor() async {
        let sawMainThread = ThreadFlag()
        let service = VolumeService(
            enumerator: { _, _ in
                sawMainThread.recordIfMain()
                return [URL(fileURLWithPath: "/", isDirectory: true)]
            },
            attributeReader: { _ in
                sawMainThread.recordIfMain()
                return .init(isLocal: true, isBrowsable: true, name: "Macintosh HD")
            }
        )
        let model = DiskUsageModel(
            volumeService: service,
            capacityReader: { _ in
                sawMainThread.recordIfMain()
                return .init(total: 100, available: 50)
            },
            now: { Date() }
        )

        model.refresh()
        await model.waitForRefresh()

        XCTAssertFalse(
            sawMainThread.didRunOnMain,
            "볼륨 열거/용량 조회가 메인 스레드에서 돌았다 — 느린 마운트 하나가 앱 전체를 멈춘다"
        )
        XCTAssertEqual(model.volumes.map(\.name), ["Macintosh HD"], "결과 반영은 그대로 되어야 한다")
    }

    /// 이름 조회가 볼륨당 **한 번**이어야 한다 — 예전에는 열거가 읽은 속성을 버리고
    /// `displayName(of:)`이 같은 조회를 다시 했다(볼륨 수만큼 중복 IO).
    func testRefresh_readsVolumeAttributesOncePerVolume() async {
        let counter = CallCounter()
        let mounted = [url("/"), url("/Volumes/USB")]
        let service = VolumeService(
            enumerator: { _, _ in mounted },
            attributeReader: { url in
                counter.increment(url.path)
                return .init(isLocal: true, isBrowsable: true, name: url.lastPathComponent)
            }
        )
        let model = DiskUsageModel(
            volumeService: service,
            capacityReader: { _ in .init(total: 10, available: 5) },
            now: { Date() }
        )

        model.refresh()
        await model.waitForRefresh()

        XCTAssertEqual(counter.count(for: "/"), 1)
        XCTAssertEqual(counter.count(for: "/Volumes/USB"), 1)
    }

    /// 조회 클로저는 백그라운드에서 불리므로 기록도 스레드 안전해야 한다.
    private final class ThreadFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func recordIfMain() {
            guard Thread.isMainThread else { return }
            lock.lock(); defer { lock.unlock() }
            flag = true
        }

        var didRunOnMain: Bool {
            lock.lock(); defer { lock.unlock() }
            return flag
        }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func increment(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            counts[key, default: 0] += 1
        }

        func count(for key: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[key] ?? 0
        }
    }

    /// **창은 하나뿐**이어야 한다(D9) — 값 없는 단일 `Window` 씬인지 씬 타입으로 확인한다.
    func testDiskCapacityScene_isSingleWindow() {
        let sceneType = String(describing: type(of: UniFinderApp().body))

        XCTAssertTrue(
            sceneType.contains("Window<"),
            "디스크 용량 창이 WindowGroup이면 같은 표가 여러 벌 뜬다: \(sceneType)"
        )
    }

    /// 소스 수준 봉인 — 마운트/언마운트 통지를 구독하지 않는다(D9).
    func testDiskUsageSources_doNotObserveVolumeNotifications() throws {
        let sources = ProjectManifest.repositoryRoot.appendingPathComponent("src")
        for name in ["ViewModels/DiskUsageModel.swift", "Views/DiskUsageWindow.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(
                text.contains("didMountNotification") || text.contains("didUnmountNotification"),
                "\(name)이 마운트 통지를 구독한다 — D9는 수동 갱신만 허용한다"
            )
        }
    }
}
