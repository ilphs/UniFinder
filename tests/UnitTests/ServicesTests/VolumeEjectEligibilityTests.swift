import XCTest
@testable import UniFinder

/// `VolumeService.isEjectable` — "이 볼륨에 Eject를 제안해도 되는가" 판정 (2026-08-20).
///
/// 실제 마운트(DMG·외장 디스크)는 단위 테스트에서 재현할 수 없으므로 볼륨 속성을 주입해
/// **규칙만** 고정한다. 실제 언마운트 실행은 `VolumeEjectTests`(주입된 unmounter)가 본다.
final class VolumeEjectEligibilityTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    // MARK: - 부팅 볼륨은 절대 대상이 아니다

    /// **핵심 회귀 가드**: 외장 디스크로 부팅한 머신에서는 루트 볼륨이 `isEjectable == true`로
    /// 보고된다. 경로만 보고 판단하면 "부팅 디스크를 꺼내기"를 사용자에게 제안하게 된다.
    func testIsEjectable_rootFileSystemIsNeverEjectable_evenWhenReportedEjectable() {
        let attributes = VolumeService.VolumeAttributes(
            isLocal: true, isBrowsable: true, name: "External Boot",
            isEjectable: true, isRemovable: true, isRootFileSystem: true
        )

        XCTAssertFalse(
            VolumeService.isEjectable(url: url("/Volumes/ExternalBoot"), attributes: attributes),
            "isRootFileSystem이 참이면 경로가 무엇이든 Eject 대상이 아니다"
        )
    }

    /// `isRootFileSystem` 키가 없으면 경로가 `/`인지로 폴백한다.
    func testIsEjectable_missingRootKey_fallsBackToRootPath() {
        let attributes = VolumeService.VolumeAttributes(
            isLocal: true, isBrowsable: true, name: "Macintosh HD", isEjectable: true
        )

        XCTAssertFalse(VolumeService.isEjectable(url: url("/"), attributes: attributes))
    }

    // MARK: - 마운트된 디스크 이미지·외장 디스크

    func testIsEjectable_ejectableVolumeIsEligible() {
        let attributes = VolumeService.VolumeAttributes(
            isLocal: true, isBrowsable: true, name: "SomeApp Installer",
            isEjectable: true, isRemovable: false, isRootFileSystem: false
        )

        XCTAssertTrue(VolumeService.isEjectable(url: url("/Volumes/SomeApp"), attributes: attributes))
    }

    /// `isEjectable` 키가 없으면 `isRemovable`로 폴백한다(USB 매체).
    func testIsEjectable_removableVolumeIsEligibleWhenEjectableKeyMissing() {
        let attributes = VolumeService.VolumeAttributes(
            isLocal: true, isBrowsable: true, name: "USB", isRemovable: true, isRootFileSystem: false
        )

        XCTAssertTrue(VolumeService.isEjectable(url: url("/Volumes/USB"), attributes: attributes))
    }

    /// **두 키가 모두 없으면 `false`** — 여기서는 보수적으로 기울어야 한다.
    /// (`isBrowsable`의 "키가 없으면 표시" 기본값과 반대 방향이다: 잘못 표시된 Eject는
    ///  마운트 해제라는 파괴적 방향으로 작동한다.)
    func testIsEjectable_missingBothKeys_defaultsToNotEjectable() {
        let attributes = VolumeService.VolumeAttributes(
            isLocal: true, isBrowsable: true, name: "Data", isRootFileSystem: false
        )

        XCTAssertFalse(VolumeService.isEjectable(url: url("/Volumes/Data"), attributes: attributes))
    }

    /// 속성 자체를 못 읽은 볼륨(열거 폴백으로 만들어진 항목)도 대상이 아니다.
    func testIsEjectable_missingAttributes_isNotEjectable() {
        XCTAssertFalse(VolumeService.isEjectable(url: url("/Volumes/Unknown"), attributes: nil))
    }

    func testIsEjectable_internalFixedDiskIsNotEjectable() {
        let attributes = VolumeService.VolumeAttributes(
            isLocal: true, isBrowsable: true, name: "Data",
            isEjectable: false, isRemovable: false, isRootFileSystem: false
        )

        XCTAssertFalse(VolumeService.isEjectable(url: url("/Volumes/Data"), attributes: attributes))
    }

    // MARK: - 열거 결과가 판정을 함께 실어 온다

    /// 우클릭 시점에 볼륨 속성을 다시 조회하지 않기 위해, 판정은 **열거할 때 읽은 속성**으로
    /// 끝나야 한다(`VolumeService.resourceKeys` 주석). `LocalVolume`이 그 값을 들고 있는지 본다.
    func testLocalVolumes_carryEjectabilityWithoutExtraLookup() {
        var lookups: [String] = []
        let service = VolumeService(
            enumerator: { _, _ in [self.url("/"), self.url("/Volumes/Installer")] },
            attributeReader: { url in
                lookups.append(url.path)
                switch url.path {
                case "/":
                    return .init(isLocal: true, isBrowsable: true, name: "Macintosh HD", isRootFileSystem: true)
                case "/Volumes/Installer":
                    return .init(
                        isLocal: true, isBrowsable: true, name: "Installer",
                        isEjectable: true, isRootFileSystem: false
                    )
                default:
                    return nil
                }
            }
        )

        let volumes = service.localVolumes()

        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes.filter(\.isEjectable).map(\.displayName), ["Installer"])
        XCTAssertEqual(
            lookups.count, 2,
            "볼륨당 속성 조회는 1회여야 한다 — Eject 판정 때문에 조회가 늘면 열거 비용이 배가 된다"
        )
    }
}
