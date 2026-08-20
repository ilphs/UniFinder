import XCTest
@testable import UniFinder

/// 마운트된 볼륨 꺼내기 — `AppModel.canEject` / `eject` (2026-08-20).
///
/// 실제 마운트/언마운트는 단위 테스트에서 재현할 수 없으므로(DMG·외장 디스크 필요)
/// **볼륨 열거기와 언마운트 실행부를 모두 주입**해 정책만 고정한다.
/// 판정 규칙 자체는 `VolumeEjectEligibilityTests`, 언마운트 후처리(홈 이동)는
/// `VolumeUnmountPolicyTests`가 이미 봉인하고 있다.
@MainActor
final class VolumeEjectTests: TempDirectoryTestCase {

    /// 언마운트 요청 기록 — 요청은 백그라운드에서 완료될 수 있어 잠금을 건다.
    private final class UnmountRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [URL] = []

        func record(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            calls.append(url)
        }

        var all: [URL] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    private struct BusyVolume: LocalizedError {
        var errorDescription: String? { "the volume is in use" }
    }

    /// 가짜 볼륨 목록 — `testRoot` 하위 폴더를 볼륨처럼 취급한다.
    /// - Parameter ejectable: 이 경로들만 `isEjectable == true`로 보고한다.
    private func volumeService(volumes: [URL], ejectable: Set<String>) -> VolumeService {
        VolumeService(
            enumerator: { _, _ in volumes },
            attributeReader: { url in
                let isEjectable = ejectable.contains(url.standardizedFileURL.path)
                return .init(
                    isLocal: true,
                    isBrowsable: true,
                    name: url.lastPathComponent,
                    isEjectable: isEjectable,
                    isRemovable: isEjectable,
                    isRootFileSystem: false
                )
            }
        )
    }

    private func makeModel(
        volumes: [URL],
        ejectable: Set<String>,
        recorder: UnmountRecorder,
        failure: Error? = nil
    ) -> AppModel {
        let defaults = UserDefaults(suiteName: "VolumeEject-\(UUID().uuidString)")!
        let model = AppModel(
            settings: AppSettings(defaults: defaults),
            volumeService: volumeService(volumes: volumes, ejectable: ejectable),
            startURL: testRoot
        )
        model.volumeUnmounter = { url in
            recorder.record(url)
            return failure
        }
        return model
    }

    // MARK: - 적격 판정

    func testCanEject_onlyForEjectableVolumeRoots() throws {
        let dmg = try Fixture.makeDirectory(in: testRoot, name: "Installer")
        let internalDisk = try Fixture.makeDirectory(in: testRoot, name: "Data")
        let plainFolder = try Fixture.makeDirectory(in: testRoot, name: "Documents")
        let recorder = UnmountRecorder()
        let model = makeModel(
            volumes: [dmg, internalDisk],
            ejectable: [dmg.standardizedFileURL.path],
            recorder: recorder
        )

        XCTAssertTrue(model.canEject(dmg), "마운트된 디스크 이미지는 꺼낼 수 있어야 한다")
        XCTAssertFalse(model.canEject(internalDisk), "내장 고정 디스크는 대상이 아니다")
        XCTAssertFalse(model.canEject(plainFolder), "볼륨 루트가 아닌 일반 폴더는 대상이 아니다")
    }

    /// 사이드바와 목록이 **같은 근거**를 봐야 한다 — 판정은 `TreeModel`이 볼륨 열거 시점에
    /// 캐시한 값 하나뿐이고, 두 화면은 그것을 조회만 한다.
    func testCanEject_sharesTheSameSourceAsTheTree() throws {
        let dmg = try Fixture.makeDirectory(in: testRoot, name: "Installer")
        let recorder = UnmountRecorder()
        let model = makeModel(volumes: [dmg], ejectable: [dmg.standardizedFileURL.path], recorder: recorder)

        XCTAssertEqual(model.canEject(dmg), model.tree.isEjectableVolume(dmg))
        // 경로 표기 차이(후행 슬래시)에 흔들리지 않아야 한다 — 목록 항목 URL은 폴더 표기다.
        XCTAssertTrue(model.canEject(URL(fileURLWithPath: dmg.path, isDirectory: true)))
    }

    // MARK: - 실행

    func testEject_requestsUnmountForTheTargetVolume() async throws {
        let dmg = try Fixture.makeDirectory(in: testRoot, name: "Installer")
        let recorder = UnmountRecorder()
        let model = makeModel(volumes: [dmg], ejectable: [dmg.standardizedFileURL.path], recorder: recorder)

        model.eject(dmg)
        await Task.yield()
        try await waitUntil { recorder.all.count == 1 }

        XCTAssertEqual(recorder.all.map(\.path), [dmg.path])
        XCTAssertNil(model.transientMessage, "성공은 조용히 지나간다 — 볼륨이 사라지는 것이 곧 피드백이다")
    }

    /// 대상이 아닌 경로로 들어온 요청은 **실행하지 않는다**(메뉴 항목이 없더라도 진입점은 막는다).
    func testEject_nonEjectablePath_doesNothing() async throws {
        let plainFolder = try Fixture.makeDirectory(in: testRoot, name: "Documents")
        let recorder = UnmountRecorder()
        let model = makeModel(volumes: [], ejectable: [], recorder: recorder)

        model.eject(plainFolder)
        await Task.yield()

        XCTAssertTrue(recorder.all.isEmpty)
    }

    /// 실패는 삼키지 않는다 — 모달이 아니라 상태바 문구로 알린다(UI설계 §9).
    func testEject_failure_reportsThroughStatusBar() async throws {
        let dmg = try Fixture.makeDirectory(in: testRoot, name: "Installer")
        let recorder = UnmountRecorder()
        let model = makeModel(
            volumes: [dmg],
            ejectable: [dmg.standardizedFileURL.path],
            recorder: recorder,
            failure: BusyVolume()
        )

        model.eject(dmg)
        try await waitUntil { model.transientMessage != nil }

        XCTAssertEqual(model.transientMessage, AppModel.ejectFailureMessage(volumeName: "Installer"))
    }

    /// **연타 가드**: 언마운트는 수 초를 끌 수 있고 그동안 메뉴 항목은 활성으로 남는다.
    /// 같은 볼륨에 요청이 두 번 나가면 OS 대화상자가 겹친다.
    func testEject_repeatedRequestsWhileInFlight_areCoalesced() async throws {
        let dmg = try Fixture.makeDirectory(in: testRoot, name: "Installer")
        let recorder = UnmountRecorder()
        let gate = AsyncGate()
        let model = makeModel(volumes: [dmg], ejectable: [dmg.standardizedFileURL.path], recorder: recorder)
        model.volumeUnmounter = { url in
            recorder.record(url)
            await gate.wait()
            return nil
        }

        model.eject(dmg)
        try await waitUntil { recorder.all.count == 1 }
        model.eject(dmg)
        model.eject(dmg)
        await Task.yield()

        XCTAssertEqual(recorder.all.count, 1, "진행 중인 볼륨에는 요청이 한 번만 나가야 한다")

        // 첫 요청이 끝나면 다시 시도할 수 있어야 한다(가드가 영구히 남으면 재시도가 막힌다).
        await gate.open()
        try await waitUntil { !model.isEjectInFlight(dmg) }
        model.eject(dmg)
        try await waitUntil { recorder.all.count == 2 }
    }

    // MARK: - 대기 헬퍼

    /// 조건이 참이 될 때까지 짧게 폴링한다(고정 `sleep`은 느리고 불안정하다).
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("조건이 \(timeout)초 안에 충족되지 않았다"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 진행 중 상태를 붙잡아 두기 위한 최소 게이트.
    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }
}
