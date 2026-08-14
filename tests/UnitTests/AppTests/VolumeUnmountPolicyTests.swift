import XCTest
@testable import UniFinder

/// M3 T1 — 볼륨 언마운트 시 "표시 중 경로를 떠나야 하는가" 판정 (ralph 작성).
///
/// 실제 마운트/언마운트는 단위 테스트에서 재현할 수 없으므로(외장 디스크·DMG 필요),
/// 판정 로직만 순수 함수로 분리해 고정한다. 통지 수신/트리 갱신은 `TreeModel`이,
/// 실제 이동은 `AppModel.handleVolumeUnmounted`가 이 판정 결과로 수행한다.
@MainActor
final class VolumeUnmountPolicyTests: TempDirectoryTestCase {

    func testShouldLeave_whenCurrentPathIsInsideUnmountedVolume() throws {
        let volume = try Fixture.makeDirectory(in: testRoot, name: "ExternalDisk")
        let current = try Fixture.makeDirectory(in: volume, name: "Photos")

        XCTAssertTrue(
            AppModel.shouldLeaveUnmountedVolume(current: current, unmounted: volume),
            "분리된 볼륨 하위를 보고 있으면 떠나야 한다(설계서 §6)"
        )
    }

    func testShouldLeave_whenCurrentPathIsTheUnmountedVolumeItself() throws {
        let volume = try Fixture.makeDirectory(in: testRoot, name: "ExternalDisk")

        XCTAssertTrue(AppModel.shouldLeaveUnmountedVolume(current: volume, unmounted: volume))
    }

    func testShouldNotLeave_whenCurrentPathIsUnrelatedAndStillExists() throws {
        let volume = try Fixture.makeDirectory(in: testRoot, name: "ExternalDisk")
        let elsewhere = try Fixture.makeDirectory(in: testRoot, name: "elsewhere")

        XCTAssertFalse(
            AppModel.shouldLeaveUnmountedVolume(current: elsewhere, unmounted: volume),
            "무관한 볼륨이 빠졌다고 사용자를 홈으로 끌고 가면 안 된다"
        )
    }

    /// 볼륨 URL을 실어주지 않는 통지도 있다 — 그때는 현재 경로의 존재 여부로 판단한다.
    func testShouldLeave_whenVolumeURLIsUnknownButCurrentPathVanished() {
        let ghost = testRoot.appendingPathComponent("gone", isDirectory: true)

        XCTAssertTrue(
            AppModel.shouldLeaveUnmountedVolume(current: ghost, unmounted: nil),
            "볼륨 URL이 없으면 현재 경로 존재 여부로 판단해야 한다"
        )
    }

    func testShouldNotLeave_whenVolumeURLIsUnknownAndCurrentPathStillExists() {
        XCTAssertFalse(AppModel.shouldLeaveUnmountedVolume(current: testRoot, unmounted: nil))
    }

    /// 파일(디렉터리 아님)을 가리키고 있으면 정상 상태가 아니므로 떠난다.
    func testShouldLeave_whenCurrentPathIsNotADirectory() throws {
        let file = try Fixture.makeFile(in: testRoot, name: "not-a-folder.txt")

        XCTAssertTrue(AppModel.shouldLeaveUnmountedVolume(current: file, unmounted: nil))
    }
}
