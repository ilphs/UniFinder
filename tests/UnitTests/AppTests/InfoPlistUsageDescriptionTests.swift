import XCTest
@testable import UniFinder

/// TCC 사용 목적 문구 회귀 테스트 (code review 보안/프라이버시 #7).
///
/// `TreeModel.favoriteURLs()`가 데스크탑/다운로드/서류를 즐겨찾기로 노출하므로,
/// 해당 폴더 접근 시 macOS가 TCC 프롬프트를 띄운다. Info.plist에 사용 목적 문구가 없으면
/// 프롬프트 대신 앱이 즉시 종료되므로, 빌드 산출물에 실제로 들어갔는지 검증한다.
final class InfoPlistUsageDescriptionTests: XCTestCase {

    /// 앱 타깃의 번들(테스트 번들이 아니라 host app). project.yml의 INFOPLIST_KEY_* 결과를 본다.
    private var appBundle: Bundle {
        Bundle(for: AppSettings.self)
    }

    func testTCCUsageDescriptions_arePresentAndNonEmpty() throws {
        let requiredKeys = [
            "NSDesktopFolderUsageDescription",
            "NSDocumentsFolderUsageDescription",
            "NSDownloadsFolderUsageDescription",
        ]

        for key in requiredKeys {
            let value = appBundle.object(forInfoDictionaryKey: key) as? String
            XCTAssertNotNil(value, "\(key)가 Info.plist에 없음 — 즐겨찾기 폴더 접근 시 앱이 종료된다")
            XCTAssertFalse(
                (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(key) 문구가 비어 있음"
            )
        }
    }
}
