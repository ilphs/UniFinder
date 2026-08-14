import XCTest
@testable import UniFinder

/// `NavigationModel` 단위 테스트.
/// 대상(T2 수용 기준): navigate/back/forward/up 시나리오, forward 클리어,
/// 루트 경계, 동일 경로 재이동(히스토리 미오염).
@MainActor
final class NavigationModelTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/")
    private let home = URL(fileURLWithPath: "/Users/tester")
    private let documents = URL(fileURLWithPath: "/Users/tester/Documents")
    private let downloads = URL(fileURLWithPath: "/Users/tester/Downloads")

    // MARK: - 기본 이동

    func testNavigate_updatesCurrentURLAndPushesBackStack() {
        let model = NavigationModel(startURL: home)
        model.navigate(to: documents)

        XCTAssertEqual(model.currentURL, documents)
        XCTAssertEqual(model.backStack, [home])
        XCTAssertTrue(model.forwardStack.isEmpty)
    }

    func testBackThenForward_roundTripsToSameURL() {
        let model = NavigationModel(startURL: home)
        model.navigate(to: documents)
        model.navigate(to: downloads)

        model.goBack()
        XCTAssertEqual(model.currentURL, documents)

        model.goBack()
        XCTAssertEqual(model.currentURL, home)

        model.goForward()
        XCTAssertEqual(model.currentURL, documents)

        model.goForward()
        XCTAssertEqual(model.currentURL, downloads)
    }

    // MARK: - forward 클리어

    func testNavigate_afterGoBack_clearsForwardStack() {
        let model = NavigationModel(startURL: home)
        model.navigate(to: documents)
        model.goBack()
        XCTAssertFalse(model.forwardStack.isEmpty)

        model.navigate(to: downloads)

        XCTAssertTrue(model.forwardStack.isEmpty, "새 이동 시 forward 스택은 브라우저 관례대로 클리어되어야 함")
        XCTAssertEqual(model.currentURL, downloads)
    }

    // MARK: - 경계 조건

    func testGoBack_withEmptyBackStack_isNoOp() {
        let model = NavigationModel(startURL: home)
        model.goBack()
        XCTAssertEqual(model.currentURL, home)
        XCTAssertTrue(model.backStack.isEmpty)
    }

    func testGoForward_withEmptyForwardStack_isNoOp() {
        let model = NavigationModel(startURL: home)
        model.goForward()
        XCTAssertEqual(model.currentURL, home)
    }

    func testGoUp_atRoot_isNoOp() {
        let model = NavigationModel(startURL: root)
        model.goUp()
        XCTAssertEqual(model.currentURL, root)
        XCTAssertTrue(model.backStack.isEmpty)
    }

    func testGoUp_fromNestedPath_movesToParentAndPushesHistory() {
        let model = NavigationModel(startURL: documents)
        model.goUp()
        XCTAssertEqual(model.currentURL, home)
        XCTAssertEqual(model.backStack, [documents])
    }

    // MARK: - 동일 경로 재이동

    func testNavigate_toSameCurrentURL_doesNotPolluteHistory() {
        let model = NavigationModel(startURL: home)
        model.navigate(to: home)

        XCTAssertEqual(model.currentURL, home)
        XCTAssertTrue(model.backStack.isEmpty, "동일 경로로의 재이동은 히스토리를 오염시키면 안 됨")
    }

    // MARK: - canGoBack / canGoForward

    func testCanGoBackAndForward_reflectStackState() {
        let model = NavigationModel(startURL: home)
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canGoForward)

        model.navigate(to: documents)
        XCTAssertTrue(model.canGoBack)
        XCTAssertFalse(model.canGoForward)

        model.goBack()
        XCTAssertFalse(model.canGoBack)
        XCTAssertTrue(model.canGoForward)
    }

    // MARK: - 연속 이동 시나리오

    func testMultipleNavigations_backStackOrderIsPreserved() {
        let model = NavigationModel(startURL: home)
        let a = home.appendingPathComponent("A")
        let b = home.appendingPathComponent("B")
        let c = home.appendingPathComponent("C")

        model.navigate(to: a)
        model.navigate(to: b)
        model.navigate(to: c)

        XCTAssertEqual(model.backStack, [home, a, b])
        XCTAssertEqual(model.currentURL, c)
    }
}
