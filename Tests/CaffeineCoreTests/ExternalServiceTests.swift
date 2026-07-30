import Testing
@testable import CaffeineCore

@Suite("External services")
@MainActor
struct ExternalServiceTests {
    @Test
    func testLaunchAtLoginStatusIsReadOnStart() async {
        let fixture = makeFixture(launchAtLoginStatus: .enabled)

        await fixture.controller.start()

        XCTAssertEqual(
            fixture.controller.state.launchAtLogin,
            ExternalToggleState(status: .enabled)
        )
        XCTAssertTrue(
            fixture.controller.state.menuPresentation
                .launchAtLoginItem.isOn
        )
    }

    @Test
    func testToggleLaunchAtLoginRegistersAndUnregisters() async {
        let fixture = makeFixture()
        await fixture.controller.start()

        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(fixture.launchAtLogin.registerCallCount, 1)
        XCTAssertEqual(
            fixture.controller.state.launchAtLogin.status,
            .enabled
        )
        XCTAssertNil(fixture.controller.state.launchAtLogin.issue)

        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(fixture.launchAtLogin.unregisterCallCount, 1)
        XCTAssertEqual(
            fixture.controller.state.launchAtLogin.status,
            .notRegistered
        )
        XCTAssertNil(fixture.controller.state.launchAtLogin.issue)
    }

    @Test
    func testAuthoritativeEnabledStatusWinsOverRegisterError() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        fixture.launchAtLogin.registerError = TestFailure.expected
        fixture.launchAtLogin.statusAfterRegister = .enabled

        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(
            fixture.controller.state.launchAtLogin,
            ExternalToggleState(status: .enabled)
        )
    }

    @Test
    func testAuthoritativeNotRegisteredStatusWinsOverUnregisterError() async {
        let fixture = makeFixture(launchAtLoginStatus: .enabled)
        await fixture.controller.start()
        fixture.launchAtLogin.unregisterError = TestFailure.expected
        fixture.launchAtLogin.statusAfterUnregister = .notRegistered

        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(
            fixture.controller.state.launchAtLogin,
            ExternalToggleState(status: .notRegistered)
        )
    }

    @Test
    func testLaunchAtLoginFailureRollsBackToObservedStatus() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        fixture.launchAtLogin.registerError = TestFailure.expected
        fixture.launchAtLogin.statusAfterRegister = .notRegistered

        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(
            fixture.controller.state.launchAtLogin.status,
            .notRegistered
        )
        XCTAssertEqual(
            fixture.controller.state.launchAtLogin.issue,
            .changeFailed
        )
    }

    @Test
    func testLaunchAtLoginOutsideApplicationsShowsActionableMoveHint() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        fixture.launchAtLogin.registerError =
            ApplicationInstallationError.moveToApplications
        fixture.launchAtLogin.statusAfterRegister = .notRegistered

        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(
            fixture.controller.state.launchAtLogin,
            ExternalToggleState(
                status: .notRegistered,
                issue: .moveToApplications
            )
        )
        XCTAssertEqual(
            fixture.controller.state.menuPresentation
                .launchAtLoginItem.subtitle,
            "Move Caffeine to /Applications"
        )
    }

    @Test
    func testLaunchAtLoginRequiresApprovalIsAQuietPendingState() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        fixture.launchAtLogin.statusAfterRegister = .requiresApproval
        var events: [CaffeineControllerEvent] = []
        fixture.controller.onEvent = { events.append($0) }

        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(
            fixture.controller.state.launchAtLogin.status,
            .requiresApproval
        )
        XCTAssertNil(fixture.controller.state.launchAtLogin.issue)
        XCTAssertFalse(
            fixture.controller.state.menuPresentation
                .launchAtLoginItem.isOn
        )
        XCTAssertEqual(
            fixture.controller.state.menuPresentation
                .launchAtLoginItem.subtitle,
            "Waiting for approval…"
        )
        XCTAssertEqual(events, [.requestLaunchAtLoginApproval])
    }

    @Test
    func testClickingPendingLaunchAtLoginReopensApproval() async {
        let fixture = makeFixture(
            launchAtLoginStatus: .requiresApproval
        )
        await fixture.controller.start()
        var events: [CaffeineControllerEvent] = []
        fixture.controller.onEvent = { events.append($0) }

        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(fixture.launchAtLogin.registerCallCount, 0)
        XCTAssertEqual(fixture.launchAtLogin.unregisterCallCount, 0)
        XCTAssertEqual(
            fixture.controller.state.launchAtLogin,
            ExternalToggleState(status: .requiresApproval)
        )
        XCTAssertEqual(events, [.requestLaunchAtLoginApproval])
    }

    @Test
    func testExternalRefreshReflectsLaunchAtLoginRevocation() async {
        let fixture = makeFixture(launchAtLoginStatus: .enabled)
        await fixture.controller.start()
        fixture.launchAtLogin.statusValue = .notRegistered

        await fixture.controller.refreshExternalState()

        XCTAssertEqual(
            fixture.controller.state.launchAtLogin,
            ExternalToggleState(status: .notRegistered)
        )
    }

    @Test
    func testLaunchAtLoginNeverWritesWakePreferences() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        let savedValueCount = fixture.preferences.savedValues.count

        await fixture.controller.toggleLaunchAtLogin()
        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(
            fixture.preferences.savedValues.count,
            savedValueCount
        )
    }
}
