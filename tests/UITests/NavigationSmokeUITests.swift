import XCTest

/// XCUITest 스모크 1본 (테스트계획 §4.4).
///
/// **목적** — 단위 테스트는 앱을 **한 번도 기동하지 않는다**. 앱 기동·MainWindow 조립·
/// Info.plist/entitlements 실효·기본 탐색 경로가 살아 있는지의 최후 안전망이 이 파일이다.
/// 게이트마다 실행한다.
///
/// **시나리오** (§4.4 그대로):
/// 앱 시작 → 홈 표시 확인 → 트리에서 Documents 선택 → 우측 갱신 확인 → 더블클릭 진입 →
/// breadcrumb 확인 → 뒤로 → 종료
///
/// **결정성** — "더블클릭 진입"의 대상은 사용자 폴더에 무엇이 있는지에 의존할 수 없다
/// (테스트계획 원칙 2). 그래서 **홈 루트에 전용 이름의 fixture 폴더**(`UniFinderSmoke-…`)를 만들어
/// 그것을 진입 대상으로 삼고, 끝나면 지운다. 사용자의 기존 파일은 읽지도 건드리지도 않는다.
///
/// fixture 위치가 홈 루트인 이유(전부 실측으로 걸러낸 것):
/// - `~/Documents`·`~/Desktop`·`~/Downloads`: 러너가 쓰려 하면 **TCC 프롬프트가 떠서 테스트가 멈춘다**
///   ("'UniFinderUITests-Runner.app'이 문서 폴더의 파일에 접근하려고 합니다") — 무인 실행 불가
/// - `$TMPDIR`/`/private/tmp`: 트리에서 닿지 않아 주소창 타이핑이 필요한데, XCUITest 합성 타이핑은
///   부하가 걸리면 글자당 200ms를 넘겨 포커스가 흔들리고 편집 모드가 접힌다(반복 실패)
/// - **홈 루트는 TCC 보호 대상이 아니고 트리의 "홈" 노드 한 번 클릭으로 닿는다**
///
/// **UI 자동화는 여기서 늘리지 않는다** (원칙 3). 세부 상호작용은 수동 게이트 소관이다.
///
/// **실행 전제** — macOS는 XCUITest에 automation mode를 요구하고, 기본값은 "부팅 세션마다
/// 사용자 인증"이다. 인증이 승인되지 않은 비대화형 셸에서는
/// `Timed out while enabling automation mode.`로 60초 만에 실패한다.
/// 준비 방법은 테스트계획서 §4.4를 참조 (`automationmodetool` 1회 설정 또는 Xcode에서 1회 인증).
/// 또한 **다른 앱이 포커스를 계속 빼앗는 데스크탑에서는 흔들린다** — 게이트 실행 중에는 화면을 비워둔다.
final class NavigationSmokeUITests: XCTestCase {

    private var app: XCUIApplication!
    private var fixtureRoot: URL!

    /// 질의 기준이 되는 창. 도움말 메뉴의 자동 생성 요소를 피하기 위해 창 하위로만 질의한다.
    private var window: XCUIElement?

    /// fixture 구조: `~/UniFinderSmoke-<8hex>/SmokeChild`
    private let childFolderName = "SmokeChild"

    private let timeout: TimeInterval = 30

    // MARK: - 수명주기

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureRoot = try makeFixture()

        app = XCUIApplication()
        app.launchArguments = [
            // FDA 웰컴 시트를 띄우지 않는다. `FullDiskAccessModel`은 `UserDefaults.standard`를 보고
            // 커맨드라인 인자는 NSArgumentDomain으로 읽히므로 **앱 코드 수정 없이** 보류 상태를 만든다.
            // (시트는 모달이라 뜨면 스모크가 첫 단계에서 막힌다)
            "-fullDiskAccessOnboardingPostponed", "YES",
            // 이전 실행의 창 복원을 끈다 — 창이 2개 뜨거나 이전 상태가 남으면 스모크가 흔들린다.
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-ApplePersistenceIgnoreState", "YES",
            // 숨김 표시·정렬은 이전 실행의 UserDefaults에서 넘어오면 목록 대조가 흔들린다 — 고정한다.
            "-showHiddenItems", "NO",
            "-sortKey", "name",
            "-sortAscending", "YES",
        ]
    }

    override func tearDownWithError() throws {
        window = nil
        if let app, app.state != .notRunning {
            app.terminate()
        }
        try removeFixture()
    }

    // MARK: - 스모크

    func testSmoke_launchNavigateEnterAndGoBack() throws {
        // 0) 예열 — **갓 빌드된 바이너리의 첫 실행**은 Gatekeeper/XProtect 스캔과 TCC 신원 재평가가
        //    겹쳐 앱이 수십 초 동안 응답 지연에 빠진다. 그 상태에서 XCUITest가 스냅샷을 뜨면
        //    "main thread busy for 30.0s"로 스모크가 통째로 무너진다(실측: 새 빌드 직후 실행에서
        //    218초 실패, 예열된 바이너리로는 27초 통과). 한 번 띄웠다 내려 스캔을 흡수한다.
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: timeout)
        app.terminate()
        _ = waitForAppState(.notRunning)

        // 1) 앱 시작
        app.launch()
        // 다른 앱이 포커스를 쥐고 있으면 클릭·키 입력이 앱에 닿지 않는다 — 명시적으로 최전면으로.
        app.activate()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: timeout), "앱 창이 뜨지 않았다 — 기동 실패")

        // 2) 홈 표시 확인 — 트리·목록이 조립되고 주소창이 홈을 가리키는지
        //
        // **모든 질의는 창 하위로 한정한다.** AppKit은 모든 앱의 "도움말" 메뉴에 검색 필드와
        // 결과 테이블(`_SC_SEARCH_FIELD` / `_SC_RESULTS_TABLE`)을 자동으로 붙인다. 앱 전역으로
        // `tables.firstMatch`/`textFields.firstMatch`를 쓰면 그 도움말 테이블·검색 필드가 잡혀
        // "목록이 있다"는 단언이 통과하면서 정작 행은 하나도 못 찾는다(실제로 이 스모크가
        // 그렇게 실패했다).
        self.window = window
        let tree = window.outlines.firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: timeout), "좌측 트리(NSOutlineView)가 없다")

        let list = window.tables.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: timeout), "우측 목록(NSTableView)이 없다")

        let homeName = Self.realHome.lastPathComponent
        XCTAssertTrue(
            breadcrumbSegment(homeName).waitForExistence(timeout: timeout),
            "시작 위치가 홈이 아니다 — breadcrumb에 '\(homeName)' 세그먼트가 없다"
        )

        // 상태바 요약("항목 N개 …")이 그려졌는지 = 목록이 실제로 로드됐다는 신호
        XCTAssertTrue(statusSummary().waitForExistence(timeout: timeout), "상태바 요약(항목 N개)이 표시되지 않았다")

        // 3) 트리에서 Documents 선택 (즐겨찾기 섹션은 기본 확장 상태다)
        //    트리 라벨은 `localizedName`이라 시스템 언어에 따라 "서류"일 수도 있다 — 후보를 모두 본다.
        let documentsURL = Self.realHome.appendingPathComponent("Documents", isDirectory: true)
        let documentsNames = displayNameCandidates(for: documentsURL)

        let documentsNode = text(anyOf: documentsNames, in: tree)
        XCTAssertTrue(
            documentsNode.waitForExistence(timeout: timeout),
            "트리 즐겨찾기에 Documents 노드가 없다(후보: \(documentsNames))"
        )
        app.activate()
        documentsNode.click()

        // 4) 우측 갱신 확인 — breadcrumb 마지막 세그먼트가 Documents로 바뀐다
        //    (breadcrumb은 localizedName이 아니라 `lastPathComponent`를 쓴다 → "Documents")
        XCTAssertTrue(
            breadcrumbSegment(documentsURL.lastPathComponent).waitForExistence(timeout: timeout),
            "트리에서 Documents를 선택했는데 우측/주소창이 갱신되지 않았다"
        )
        // 접근 권한(TCC)이 없어 목록이 비거나 오류여도 **앱은 살아 있어야 한다** — 여기서 죽으면 blocker다.
        XCTAssertEqual(app.state, .runningForeground, "Documents 진입 직후 앱이 죽었다")

        // 5) 트리에서 홈으로 돌아가 진입 대상(fixture)을 찾는다 — 클릭만으로 닿는 경로다.
        let homeNode = text(anyOf: ["홈 (\(NSUserName()))", homeName], in: tree)
        XCTAssertTrue(homeNode.waitForExistence(timeout: timeout), "트리에 홈 노드가 없다")
        app.activate()
        homeNode.click()
        XCTAssertTrue(
            breadcrumbSegment(homeName).waitForExistence(timeout: timeout),
            "트리에서 홈을 선택했는데 위치가 홈으로 돌아오지 않았다"
        )

        let fixtureName = fixtureRoot.lastPathComponent
        let fixtureRow = text(fixtureName, in: list)
        XCTAssertTrue(
            fixtureRow.waitForExistence(timeout: timeout),
            "홈 목록에 fixture 폴더 '\(fixtureName)'가 없다 — 목록 갱신 실패"
        )

        // 6) 더블클릭 진입 → breadcrumb 확인
        app.activate()
        fixtureRow.doubleClick()
        XCTAssertTrue(
            breadcrumbSegment(fixtureName).waitForExistence(timeout: timeout),
            "더블클릭으로 '\(fixtureName)'에 진입하지 못했다(breadcrumb 미갱신)"
        )
        XCTAssertTrue(
            text(childFolderName, in: list).waitForExistence(timeout: timeout),
            "진입한 폴더의 내용('\(childFolderName)')이 표시되지 않았다"
        )

        // 7) 뒤로 → 홈으로 복귀
        clickMenuItem(menu: "이동", item: "뒤로")
        XCTAssertTrue(
            breadcrumbSegment(homeName).waitForExistence(timeout: timeout),
            "[뒤로] 후 이전 위치(홈)로 돌아오지 않았다"
        )
        XCTAssertTrue(
            text(fixtureName, in: list).waitForExistence(timeout: timeout),
            "[뒤로] 후 목록이 이전 폴더 내용으로 복원되지 않았다"
        )

        // 8) 종료 — 창 닫힘 경로(`AppModel.stop()`: 감시자 해제)까지 크래시 없이 지나가는지 본다
        app.terminate()
        XCTAssertTrue(waitForAppState(.notRunning), "앱이 정상 종료되지 않았다")
    }

    // MARK: - 조작 헬퍼

    /// 메뉴바 항목을 열고 하위 항목을 클릭한다.
    ///
    /// 메뉴바는 **최전면 앱의 것만 그려진다.** 다른 앱이 잠깐 포커스를 가져가면 메뉴 항목의 프레임이
    /// `{{0,1440},{0,0}}`가 되어 `Not hittable` 재시도가 폭주하다 자동화 연결이 끊긴다(실측 실패).
    /// 그래서 매 시도마다 앱을 활성화하고 hittable 여부를 확인한 뒤에만 클릭한다.
    private func clickMenuItem(menu: String, item: String) {
        for _ in 1...3 {
            app.activate()

            let menuBarItem = app.menuBars.menuBarItems[menu]
            guard menuBarItem.waitForExistence(timeout: 10), menuBarItem.isHittable else { continue }
            menuBarItem.click()

            let menuItem = app.menuBars.menuItems[item]
            if menuItem.waitForExistence(timeout: 10), menuItem.isHittable {
                menuItem.click()
                return
            }
            // 열려 있는 메뉴를 닫고 다시 시도한다.
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }
        XCTFail("메뉴 '\(menu) > \(item)'를 실행하지 못했다 — 다른 앱이 포커스를 쥐고 있는지 확인")
    }

    // MARK: - 질의 헬퍼

    /// 텍스트를 **label/value/title 어디에 실려 있든** 잡는다.
    ///
    /// 트리·목록 셀은 `NSTextField(labelWithString:)`이라 접근성 트리에서 문자열이 `AXValue`에만
    /// 실린다(`AXTitle`/`AXDescription`은 빈 값). 반면 breadcrumb 버튼은 SwiftUI가 `AXDescription`에
    /// 싣는다. 어느 쪽이 `XCUIElement.label`로 매핑되는지에 의존하면 OS/Xcode 판올림마다 깨지므로
    /// 세 속성을 모두 본다.
    private func text(_ value: String, in container: XCUIElement) -> XCUIElement {
        text(anyOf: [value], in: container)
    }

    private func text(anyOf values: [String], in container: XCUIElement) -> XCUIElement {
        let predicate = NSPredicate(
            format: "value IN %@ OR label IN %@ OR title IN %@",
            values, values, values
        )
        return container.staticTexts.matching(predicate).firstMatch
    }

    /// breadcrumb 세그먼트 버튼. 홈 세그먼트는 아이콘이 함께 있어 라벨이 정확히 일치하지 않을 수
    /// 있으므로 `CONTAINS`로 본다.
    private func breadcrumbSegment(_ title: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@ OR title CONTAINS %@",
            title, title, title
        )
        return (window ?? app).buttons.matching(predicate).firstMatch
    }

    /// 상태바 요약("항목 N개 …").
    private func statusSummary() -> XCUIElement {
        let predicate = NSPredicate(format: "value BEGINSWITH '항목 ' OR label BEGINSWITH '항목 '")
        return (window ?? app).staticTexts.matching(predicate).firstMatch
    }

    private func waitForAppState(_ state: XCUIApplication.State) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state == state { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return app.state == state
    }

    // MARK: - fixture

    /// 테스트 프로세스의 홈이 아니라 **실제 사용자 홈**.
    ///
    /// XCUITest 러너는 조건에 따라 샌드박스로 뜨고, 그러면 `homeDirectoryForCurrentUser`가
    /// `~/Library/Containers/<id>/Data`를 돌려준다(실제로 이 프로젝트에서 breadcrumb 단언이
    /// 'Data'를 찾다 실패했다). `getpwuid`는 샌드박스와 무관하게 실제 홈을 준다.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `TreeModel.displayName(for:)`이 만들 수 있는 표시 이름 후보.
    /// (시스템 언어에 따라 `localizedName`이 "서류"가 될 수 있고, 접근이 막히면 마지막 경로 성분이 된다)
    private func displayNameCandidates(for url: URL) -> [String] {
        var names = [url.lastPathComponent]
        if let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName,
           !localized.isEmpty {
            names.append(localized)
        }
        let displayName = FileManager.default.displayName(atPath: url.path)
        if !displayName.isEmpty { names.append(displayName) }
        return Array(Set(names))
    }

    /// fixture 폴더 이름 접두사. 삭제 가드가 이 접두사에만 걸리므로 바꾸면 안 된다.
    private static let fixturePrefix = "UniFinderSmoke-"

    /// fixture는 **홈 루트**에 만든다 (이유는 타입 주석 참조). 끝나면 지운다.
    private static var fixtureBase: URL { realHome }

    private func makeFixture() throws -> URL {
        removeStaleFixtures()
        let suffix = String(UUID().uuidString.prefix(8))
        let root = Self.fixtureBase
            .appendingPathComponent("\(Self.fixturePrefix)\(suffix)", isDirectory: true)

        let child = root.appendingPathComponent(childFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        // 진입 전 폴더에 파일도 하나 둔다 — 폴더 우선 정렬이 깨지면 첫 행이 파일이 되어 드러난다.
        try Data("smoke".utf8).write(to: root.appendingPathComponent("smoke.txt"))
        return root
    }

    private func removeFixture() throws {
        guard let fixtureRoot else { return }
        // 원칙 1 — 테스트가 만든 전용 폴더 밖은 절대 지우지 않는다.
        guard Self.isFixturePath(fixtureRoot) else {
            XCTFail("fixture 경로가 예상 위치 밖이다: \(fixtureRoot.path)")
            return
        }
        try? FileManager.default.removeItem(at: fixtureRoot)
        self.fixtureRoot = nil
    }

    /// 지울 수 있는 것은 **홈 루트 바로 아래의 전용 접두사 폴더**뿐이다 (원칙 1의 안전장치).
    private static func isFixturePath(_ url: URL) -> Bool {
        let base = fixtureBase.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        return url.deletingLastPathComponent().resolvingSymlinksInPath().path == base
            && url.lastPathComponent.hasPrefix(fixturePrefix)
            && path != base
    }

    /// 이전 실행이 크래시로 남긴 fixture를 정리한다(사용자 Documents에 쓰레기를 쌓지 않는다).
    private func removeStaleFixtures() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.fixtureBase,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where Self.isFixturePath(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
