import XCTest
@testable import UniFinder

/// `AppEnvironment` (다중 창 지원 — 새 API) 단위 테스트.
///
/// 창마다 독립된 `AppModel`(탐색·트리·히스토리)을 갖되, 앱 전역 상태(클립보드·FDA·설정)는
/// 창 사이에 공유되는 하나의 인스턴스로 유지된다. `AppEnvironment`는 그 공유 인스턴스의
/// 소유자이자, "지금 열려 있는 창이 몇 개인가"를 아는 유일한 지점이다 — 이 카운트가
/// 온보딩 시트를 띄울 대표 창(`onboardingPresenterID`)과 마지막 창이 닫힐 때만 전역 자원을
/// 정리해도 되는지(`hasOpenWindows`)를 결정한다.
///
/// **격리**: `AppEnvironment.shared`나 `UserDefaults.standard`를 여기서 절대 건드리지 않는다 —
/// 주입 가능한 생성자로 매 테스트마다 독립된 인스턴스를 만든다.
@MainActor
final class AppEnvironmentTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let name = "UniFinderTests-AppEnvironment-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    /// 테스트 전용 격리 인스턴스. `.shared`를 대체하지 않고 나란히 존재해야 한다.
    private func makeEnvironment() -> AppEnvironment {
        AppEnvironment(
            settings: AppSettings(defaults: makeDefaults()),
            clipboard: ClipboardModel(pasteboard: NSPasteboard(name: NSPasteboard.Name("UniFinderTests-Env-\(UUID().uuidString)"))),
            fullDiskAccess: FullDiskAccessModel(defaults: makeDefaults())
        )
    }

    // MARK: - register / unregister 기본 동작

    func testRegister_addsToOpenWindowIDs() {
        let env = makeEnvironment()
        let id = UUID()

        env.register(id)

        XCTAssertEqual(env.openWindowIDs, [id])
        XCTAssertTrue(env.hasOpenWindows)
    }

    /// 같은 id를 중복 등록해도 두 번 쌓이면 안 된다(창 하나가 실수로 두 번 start되는 경로 방어).
    func testRegister_duplicateID_isIgnored() {
        let env = makeEnvironment()
        let id = UUID()

        env.register(id)
        env.register(id)

        XCTAssertEqual(env.openWindowIDs, [id], "중복 등록이 무시되지 않으면 창 카운트가 부풀어 마지막 창 판정(hasOpenWindows)이 틀어진다")
    }

    /// 해제 후에도 남은 항목들의 **상대적 순서**가 유지되어야 한다(선착순 승계 판정의 전제).
    func testUnregister_removesID_andKeepsRemainingOrder() {
        let env = makeEnvironment()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        env.register(first)
        env.register(second)
        env.register(third)

        env.unregister(second)

        XCTAssertEqual(env.openWindowIDs, [first, third])
    }

    /// 등록된 적 없는 id를 해제해도 안전해야 한다(경쟁 상황·중복 stop 방어).
    func testUnregister_unknownID_doesNothing() {
        let env = makeEnvironment()
        let known = UUID()
        env.register(known)

        env.unregister(UUID())

        XCTAssertEqual(env.openWindowIDs, [known])
    }

    // MARK: - onboardingPresenterID 승계

    /// 첫 번째로 등록된 창이 온보딩 시트를 띄울 대표 창이다(웰컴 시트가 창마다 중복으로 뜨면 안 된다).
    func testOnboardingPresenterID_isFirstRegisteredWindow() {
        let env = makeEnvironment()
        let first = UUID()
        let second = UUID()

        env.register(first)
        env.register(second)

        XCTAssertEqual(env.onboardingPresenterID, first)
    }

    /// **핵심 회귀**: 대표 창(첫 등록)이 닫히면 다음으로 오래된 창이 대표 자리를 승계해야 한다.
    /// 승계하지 않으면 남은 창이 있는데도 온보딩 시트를 다시 띄울 창이 없어져 FDA 안내가 사라진다.
    func testOnboardingPresenterID_succeedsToNextWindow_whenHostWindowCloses() {
        let env = makeEnvironment()
        let host = UUID()
        let second = UUID()
        let third = UUID()
        env.register(host)
        env.register(second)
        env.register(third)
        XCTAssertEqual(env.onboardingPresenterID, host, "전제 확인")

        env.unregister(host)

        XCTAssertEqual(env.onboardingPresenterID, second, "대표 창이 닫히면 다음으로 오래된 창이 승계해야 한다")
    }

    /// 대표가 아닌 창이 닫히는 경우에는 대표가 바뀌지 않는다.
    func testOnboardingPresenterID_unaffected_whenNonHostWindowCloses() {
        let env = makeEnvironment()
        let host = UUID()
        let other = UUID()
        env.register(host)
        env.register(other)

        env.unregister(other)

        XCTAssertEqual(env.onboardingPresenterID, host)
    }

    /// 전부 닫히면 대표도 없어야 한다.
    func testOnboardingPresenterID_isNil_whenNoWindowsOpen() {
        let env = makeEnvironment()
        let id = UUID()
        env.register(id)

        env.unregister(id)

        XCTAssertNil(env.onboardingPresenterID)
    }

    // MARK: - hasOpenWindows

    func testHasOpenWindows_falseInitially() {
        let env = makeEnvironment()
        XCTAssertFalse(env.hasOpenWindows)
    }

    func testHasOpenWindows_becomesFalse_onlyAfterAllWindowsClose() {
        let env = makeEnvironment()
        let a = UUID()
        let b = UUID()
        env.register(a)
        env.register(b)

        env.unregister(a)
        XCTAssertTrue(env.hasOpenWindows, "창이 하나 남아 있으면 아직 전역 자원을 정리하면 안 된다")

        env.unregister(b)
        XCTAssertFalse(env.hasOpenWindows, "마지막 창까지 닫히면 전역 자원을 정리해도 되는 시점이다")
    }

    // MARK: - 격리: 주입 생성자로 만든 인스턴스끼리 서로를 오염시키지 않는다

    /// **`AppEnvironment.shared`를 여기서 인스턴스화하지 않는다** (reviewer m5).
    ///
    /// 예전 판본은 `.shared`를 기준선으로 읽어 비교했는데, 그 접근 한 번이
    /// `AppSettings(defaults: .standard)`를 만들고 `AppSettings.init`의 "키 부재 → 기본 3개 시딩 +
    /// **standard 도메인 쓰기**" 경로를 실행시킨다 — 즉 **테스트 실행이 개발 머신의 실제 앱 설정에
    /// 즐겨찾기를 써넣을 수 있었다.** UI 스모크가 `-favoritePaths`로 지키는 원칙과도 어긋난다.
    ///
    /// 검증하려던 성질("주입 인스턴스는 독립적이다")은 `.shared` 없이 **주입 인스턴스 2개**로
    /// 그대로 확인된다 — 오히려 싱글턴 오염 가능성에 기대지 않아 단언이 더 강해진다.
    func testInjectedInstances_areIndependentOfEachOther() {
        let first = makeEnvironment()
        let second = makeEnvironment()
        let id = UUID()

        first.register(id)

        XCTAssertEqual(first.openWindowIDs, [id], "전제 확인 — 조작한 인스턴스에는 반영돼야 한다")
        XCTAssertTrue(
            second.openWindowIDs.isEmpty,
            "한 인스턴스의 조작이 다른 인스턴스에 새어나갔다 — 테스트 간 오염 위험"
        )
    }

    /// 주입 인스턴스가 들고 있는 `settings`/`clipboard`/`fullDiskAccess`도 서로 다른 인스턴스여야 한다.
    func testInjectedInstances_ownDistinctModels() {
        let first = makeEnvironment()
        let second = makeEnvironment()

        XCTAssertFalse(first.settings === second.settings)
        XCTAssertFalse(first.clipboard === second.clipboard)
        XCTAssertFalse(first.fullDiskAccess === second.fullDiskAccess)
    }
}
