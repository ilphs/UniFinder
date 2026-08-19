import XCTest
@testable import UniFinder

/// `VolumeService` — 볼륨 열거의 단일 권위 (후속 T1).
///
/// 실제 마운트 상태에 의존하면 개발 머신마다 결과가 달라져 단언을 쓸 수 없다.
/// 열거기와 리소스 조회를 모두 주입해 규칙만 검증한다.
final class VolumeServiceTests: XCTestCase {

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `URLResourceValues`의 볼륨 프로퍼티는 get-only라 테스트가 값을 조립할 수 없다.
    /// 그래서 서비스는 속성 조회를 `VolumeAttributes`로 좁혀 주입받는다.
    /// - Parameter known: 조회에 성공하는 볼륨. 여기 없는 URL은 "조회 실패"(제외 대상)다.
    private func service(
        volumes: [URL]?,
        known: [String: VolumeService.VolumeAttributes]
    ) -> VolumeService {
        VolumeService(
            enumerator: { _, options in
                XCTAssertTrue(
                    options.contains(.skipHiddenVolumes),
                    "숨김 볼륨 스킵 옵션이 빠지면 사이드바에 시스템 내부 볼륨이 쏟아진다"
                )
                return volumes
            },
            attributeReader: { url in known[url.path] }
        )
    }

    func testLocalVolumeURLs_keepsLocalBrowsableVolumesOnly() {
        let service = service(
            volumes: [url("/"), url("/Volumes/USB"), url("/Volumes/NetShare")],
            known: [
                "/": .init(isLocal: true, isBrowsable: true),
                "/Volumes/USB": .init(isLocal: true, isBrowsable: true),
                "/Volumes/NetShare": .init(isLocal: false, isBrowsable: true),
            ]
        )

        XCTAssertEqual(
            service.localVolumeURLs().map(\.path),
            ["/", "/Volumes/USB"],
            "네트워크 볼륨(volumeIsLocal == false)은 설계서 §1.2 비목표라 제외해야 한다"
        )
    }

    func testLocalVolumeURLs_nonBrowsableVolumeIsExcluded() {
        let service = service(
            volumes: [url("/"), url("/Volumes/Hidden")],
            known: [
                "/": .init(isLocal: true, isBrowsable: true),
                "/Volumes/Hidden": .init(isLocal: true, isBrowsable: false),
            ]
        )

        XCTAssertEqual(service.localVolumeURLs().map(\.path), ["/"])
    }

    /// `volumeIsBrowsable` 키가 없으면 **표시하는 쪽**으로 기운다(이전 `TreeModel` 구현과 동일).
    func testLocalVolumeURLs_missingBrowsableKey_defaultsToVisible() {
        let service = service(
            volumes: [url("/Volumes/Data")],
            known: ["/Volumes/Data": .init(isLocal: true, isBrowsable: nil)]
        )

        XCTAssertEqual(service.localVolumeURLs().map(\.path), ["/Volumes/Data"])
    }

    /// 리소스 조회가 실패한 볼륨은 판단 근거가 없으므로 제외한다.
    func testLocalVolumeURLs_unreadableVolumeIsExcluded() {
        let service = service(
            volumes: [url("/"), url("/Volumes/Broken")],
            known: ["/": .init(isLocal: true, isBrowsable: true)]
        )

        XCTAssertEqual(service.localVolumeURLs().map(\.path), ["/"])
    }

    /// 열거 실패는 "볼륨 없음"이 아니라 루트 폴백이다 — 섹션이 통째로 사라지면 사용자가 갈 곳을 잃는다.
    func testLocalVolumeURLs_enumerationFailure_fallsBackToRoot() {
        let service = service(volumes: nil, known: [:])

        XCTAssertEqual(service.localVolumeURLs().map(\.path), ["/"])
        XCTAssertEqual(VolumeService.fallbackURLs.map(\.path), ["/"])
    }

    /// 결과 URL은 폴더 표준형이어야 한다 — 트리가 이 값을 인덱스 키로 그대로 쓴다.
    func testLocalVolumeURLs_returnsDirectoryStyleURLs() {
        let service = service(
            volumes: [URL(fileURLWithPath: "/Volumes/USB")],
            known: ["/Volumes/USB": .init(isLocal: true, isBrowsable: true)]
        )

        let result = service.localVolumeURLs()
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].hasDirectoryPath, "폴더 표기가 아니면 PathKey 기준이 트리와 어긋난다")
    }

    func testDisplayName_prefersVolumeName() {
        let service = service(
            volumes: [url("/Volumes/USB")],
            known: ["/Volumes/USB": .init(isLocal: true, isBrowsable: true, name: "Backup Drive")]
        )

        XCTAssertEqual(service.displayName(of: url("/Volumes/USB")), "Backup Drive")
    }

    func testDisplayName_fallsBackToLastPathComponent() {
        let service = service(volumes: [], known: [:])

        XCTAssertEqual(service.displayName(of: url("/Volumes/Untitled")), "Untitled")
        XCTAssertEqual(service.displayName(of: url("/")), "/")
    }

    /// **회귀 가드**: `FileManager.mountedVolumeURLs` 직접 호출은 `VolumeService` 한 곳에만 있어야 한다.
    /// 다른 곳에서 다시 부르면 필터 규칙이 갈라져 사이드바와 용량 창이 다른 볼륨을 보여준다.
    func testMountedVolumeURLs_hasSingleCallSiteInSources() throws {
        let sources = ProjectManifest.repositoryRoot.appendingPathComponent("src")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))

        var callSites: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            if text.contains("mountedVolumeURLs") {
                callSites.append(fileURL.lastPathComponent)
            }
        }

        XCTAssertEqual(
            callSites.sorted(), ["VolumeService.swift"],
            "mountedVolumeURLs 호출부가 VolumeService 밖에도 있다: \(callSites)"
        )
    }
}
