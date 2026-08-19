import SwiftUI
import XCTest
@testable import UniFinder

/// ⌘R의 소유자는 **정확히 하나**다 (reviewer minor #8 / ⌘I가 세운 원칙의 승계).
///
/// 예전에는 메뉴바의 `View > Refresh`와 Disk Usage 창 안의 `Refresh` 버튼이 둘 다 ⌘R을 달고
/// 있었다. AppKit은 ⌘ 단축키를 responder chain보다 메인 메뉴에서 먼저 찾고, 메뉴 항목이
/// 비활성이면 이벤트가 창으로 떨어진다 — 즉 **어느 쪽이 반응하는지가 포커스 상태와 메뉴 순서에
/// 좌우된다**. 소유자를 메뉴바 하나로 고정하고, "무엇을 새로고침할지"는 활성 씬이 게시한다.
///
/// 메뉴 항목의 단축키는 앱을 띄우지 않는 한 런타임으로 열거할 수 없어(⌘I 테스트와 같은 사정)
/// 소스가 유일한 근거다.
@MainActor
final class RefreshShortcutOwnershipTests: XCTestCase {

    private func sourceLines(_ relativePath: String) throws -> [String] {
        let url = ProjectManifest.repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    /// SwiftUI 메뉴/뷰에서 ⌘R을 단 지점이 하나뿐인지 — 소스 전체를 훑는다.
    func testSources_haveExactlyOneCommandRShortcut() throws {
        let sources = ProjectManifest.repositoryRoot.appendingPathComponent("src")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))

        var swiftUIOccurrences: [String] = []
        var appKitOccurrences: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                if trimmed.contains(#"keyboardShortcut("r""#) {
                    swiftUIOccurrences.append("\(fileURL.lastPathComponent): \(trimmed)")
                }
                if trimmed.contains(#"key: "r""#) {
                    appKitOccurrences.append("\(fileURL.lastPathComponent): \(trimmed)")
                }
            }
        }

        XCTAssertEqual(
            swiftUIOccurrences.count, 1,
            "SwiftUI 쪽 ⌘R 등록 지점은 메뉴바 하나여야 한다: \(swiftUIOccurrences)"
        )
        XCTAssertTrue(
            swiftUIOccurrences.allSatisfy { $0.hasPrefix("AppCommands.swift") },
            "예상 밖 파일이 ⌘R을 등록했다: \(swiftUIOccurrences)"
        )
        // 컨텍스트 메뉴(빈 영역 우클릭)의 Refresh는 ⌘I 사례와 같은 이유로 허용된다 —
        // 목록이 first responder일 때만 유효한 항목이고, 메뉴바와 같은 대상을 새로고침한다.
        XCTAssertEqual(
            appKitOccurrences.count, 1,
            "AppKit 컨텍스트 메뉴의 ⌘R 등록 지점은 파일 목록 하나여야 한다: \(appKitOccurrences)"
        )
        XCTAssertTrue(
            appKitOccurrences.allSatisfy { $0.hasPrefix("FileListBridge.swift") },
            "예상 밖 파일이 컨텍스트 메뉴 ⌘R을 등록했다: \(appKitOccurrences)"
        )
    }

    /// Disk Usage 창의 Refresh 버튼은 **단축키를 갖지 않는다**(버튼 자체는 남는다 — D9).
    func testDiskUsageWindow_refreshButtonHasNoShortcutButStillExists() throws {
        let lines = try sourceLines("src/Views/DiskUsageWindow.swift")

        XCTAssertTrue(
            lines.contains { $0.contains(#"Button("Refresh")"#) },
            "수동 갱신 버튼이 사라졌다 — 자동 갱신을 하지 않는 창이라 버튼은 반드시 남아야 한다(D9)"
        )
        XCTAssertFalse(
            lines.contains { $0.contains("keyboardShortcut") },
            "Disk Usage 창이 다시 단축키를 소유했다 — ⌘R 소유자는 메뉴바 하나뿐이다"
        )
    }

    /// 두 창 모두 "무엇을 새로고침할지"를 씬 값으로 게시한다 —
    /// 게시가 없으면 메뉴바 ⌘R이 그 창에서 할 일을 잃는다.
    func testBothScenesPublishTheirRefreshAction() throws {
        for path in ["src/Views/MainWindow.swift", "src/Views/DiskUsageWindow.swift"] {
            let lines = try sourceLines(path)
            XCTAssertTrue(
                lines.contains { $0.contains(#"focusedSceneValue(\.sceneRefresh"#) },
                "\(path)가 새로고침 동작을 게시하지 않는다 — 그 창에서 ⌘R이 죽는다"
            )
        }
    }

    // MARK: - 게시 값의 계약

    /// 게시 값은 **id로만** 같음을 판단한다(클로저는 비교할 수 없다).
    /// 창마다 id가 달라야 포커스가 옮겨갈 때 새 동작이 실제로 게시된다.
    func testSceneRefreshAction_equalityIsByPublisherIdentity() {
        let first = SceneRefreshAction(id: "main-1") {}
        let sameID = SceneRefreshAction(id: "main-1") {}
        let otherID = SceneRefreshAction(id: "disk-usage") {}

        XCTAssertEqual(first, sameID)
        XCTAssertNotEqual(first, otherID)
    }

    func testSceneRefreshAction_invokesTheStoredAction() {
        var count = 0
        let action = SceneRefreshAction(id: "probe") { count += 1 }

        action()
        action()

        XCTAssertEqual(count, 2)
    }
}
