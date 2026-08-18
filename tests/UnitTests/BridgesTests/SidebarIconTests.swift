import AppKit
import XCTest
@testable import UniFinder

/// 사이드바 아이콘 (섹션 헤더 심볼 + 볼륨 노드 실제 아이콘) — 2026-08-18 사용자 요청 C단계.
@MainActor
final class SidebarIconTests: TempDirectoryTestCase {

    private var retainedViews: [NSView] = []

    private func makeDefaults() -> UserDefaults {
        let name = "com.unifinder.tests.sidebaricon.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeEmptySettings() -> AppSettings {
        let settings = AppSettings(defaults: makeDefaults())
        for url in settings.favoriteURLs { settings.removeFavorite(url) }
        return settings
    }

    // MARK: - 섹션 헤더 심볼 매핑

    /// 매핑은 **섹션 이름 문자열이 아니라 `SectionKind`** 기준이어야 한다 —
    /// A단계에서 헤더 문구가 영어로 바뀌어도 아이콘이 따라 깨지면 안 된다.
    func testSectionKind_mapsToExpectedSymbols() {
        XCTAssertEqual(TreeNode.SectionKind.favorites.symbolName, "star")
        XCTAssertEqual(TreeNode.SectionKind.home.symbolName, "house")
        XCTAssertEqual(TreeNode.SectionKind.volumes.symbolName, "internaldrive")
    }

    func testSectionSymbols_existInSFSymbols() {
        for kind in [TreeNode.SectionKind.favorites, .home, .volumes] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil),
                "SF Symbols에 '\(kind.symbolName)'이 없다 — 헤더 아이콘이 빈칸으로 그려진다"
            )
        }
    }

    /// 트리 모델이 실어 주는 심볼이 각 섹션과 짝이 맞는지 (브릿지가 그대로 셀에 넘긴다).
    func testTreeSections_carryMatchingSymbolNames() {
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: makeEmptySettings())

        XCTAssertEqual(
            model.sections.map { $0.sectionKind?.symbolName },
            ["star", "house", "internaldrive"]
        )
    }

    /// 헤더 셀이 심볼을 실제로 이미지 뷰에 넣는지 (아이콘 슬롯 자체가 없던 회귀 방지).
    func testSectionCell_configuresSymbolImage() {
        let cell = TreeSectionCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        retainedViews.append(cell)

        cell.configure(title: "Favorites", symbolName: "star")
        XCTAssertNotNil(cell.imageView?.image, "섹션 헤더에 아이콘이 그려지지 않았다")

        cell.configure(title: "Plain", symbolName: nil)
        XCTAssertNil(cell.imageView?.image, "심볼이 없는 섹션에 이전 아이콘이 남았다")
    }

    // MARK: - 볼륨 노드 아이콘

    /// 볼륨 섹션 바로 아래 노드만 실제 디스크 아이콘 대상이다.
    func testIsVolumeRoot_onlyForVolumeSectionChildren() async throws {
        _ = try Fixture.makeDirectory(in: testRoot, name: "Child")
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: makeEmptySettings())

        let volumesSection = try XCTUnwrap(model.sections.first { $0.sectionKind == .volumes })
        for node in volumesSection.children ?? [] {
            XCTAssertTrue(node.isVolumeRoot, "볼륨 루트가 실제 디스크 아이콘 대상에서 빠졌다")
        }

        let homeRoot = try XCTUnwrap(model.node(for: testRoot))
        XCTAssertFalse(homeRoot.isVolumeRoot, "홈 루트가 볼륨으로 오판됐다")

        await model.expand(homeRoot)
        let child = try XCTUnwrap(homeRoot.children?.first)
        XCTAssertFalse(child.isVolumeRoot, "일반 하위 폴더가 볼륨으로 오판됐다")
    }

    /// 볼륨 루트는 공용 폴더 아이콘과 **다른** 이미지를 받아야 한다.
    func testVolumeIcon_differsFromGenericFolderIcon() {
        let cache = VolumeIconCache()
        let root = URL(fileURLWithPath: "/")

        let icon = cache.icon(for: root)
        XCTAssertNotNil(icon, "볼륨 루트 아이콘 조회에 실패했다")

        let folder = NSWorkspace.shared.icon(for: .folder)
        XCTAssertNotEqual(
            icon?.tiffRepresentation,
            folder.tiffRepresentation,
            "볼륨 노드가 여전히 공용 폴더 아이콘을 쓰고 있다"
        )
    }

    /// **캐시 히트 검증**: 같은 볼륨을 여러 번 그려도 디스크 조회는 1회여야 한다
    /// (셀 그리기마다 `icon(forFile:)`를 치면 스크롤이 끊긴다).
    func testVolumeIconCache_looksUpOncePerVolume() {
        let cache = VolumeIconCache(lookup: { _ in NSImage(size: NSSize(width: 8, height: 8)) })
        let root = URL(fileURLWithPath: "/")

        for _ in 0..<20 {
            _ = cache.icon(for: root)
        }

        XCTAssertEqual(cache.lookupCount, 1, "셀 그리기마다 아이콘을 다시 조회하고 있다")
        XCTAssertEqual(cache.count, 1)
    }

    /// 표기(후행 슬래시·대소문자)가 달라도 같은 볼륨은 한 번만 조회한다 — `PathKey` 기준 캐시 키.
    func testVolumeIconCache_normalizesKeyAcrossNotations() {
        let cache = VolumeIconCache(lookup: { _ in NSImage(size: NSSize(width: 8, height: 8)) })

        _ = cache.icon(for: URL(fileURLWithPath: "/Volumes/Disk"))
        _ = cache.icon(for: URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true))
        _ = cache.icon(for: URL(fileURLWithPath: "/Volumes/disk"))

        XCTAssertEqual(cache.lookupCount, 1, "표기만 다른 같은 볼륨을 여러 번 조회했다")
    }

    /// 볼륨 이름 변경/마운트 통지는 `rebuildSections` → `sectionsRevision`을 거치므로,
    /// 그 카운터가 바뀔 때만 캐시가 비워져야 한다(확장마다 버려지면 캐시 의미가 없다).
    func testInvalidateVolumeIconsIfNeeded_clearsOnlyOnSectionsRevisionChange() {
        let model = TreeModel(loader: DirectoryLoader(), homeURL: testRoot, settings: makeEmptySettings())
        let bridge = SidebarTreeBridge(
            model: model,
            revision: model.revision,
            focusBroker: FocusBroker(),
            onSelect: { _ in },
            onRefresh: {}
        )
        let coordinator = bridge.makeCoordinator()
        let cache = coordinator.volumeIconCache

        coordinator.invalidateVolumeIconsIfNeeded(sectionsRevision: model.sectionsRevision)
        _ = cache.icon(for: URL(fileURLWithPath: "/"))
        XCTAssertEqual(cache.count, 1)

        // 같은 세대에서는 몇 번을 호출해도 캐시가 유지되어야 한다.
        for _ in 0..<5 {
            coordinator.invalidateVolumeIconsIfNeeded(sectionsRevision: model.sectionsRevision)
        }
        XCTAssertEqual(cache.count, 1, "섹션 재구성이 없었는데 캐시가 버려졌다")

        // 볼륨 rename 등으로 섹션이 다시 만들어지면 버려야 한다.
        model.rebuildSections()
        coordinator.invalidateVolumeIconsIfNeeded(sectionsRevision: model.sectionsRevision)
        XCTAssertEqual(cache.count, 0, "섹션 재구성 후에도 낡은 볼륨 아이콘이 남았다")
    }
}
