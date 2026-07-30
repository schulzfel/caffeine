import Testing
@testable import CaffeineCore

@Suite("Controller concurrency")
@MainActor
struct CaffeineControllerConcurrencyTests {
    @Test
    func testStaleApprovalRefreshCannotOverrideNewApprovalRetry() async {
        let power = MockPowerController()
        let helper = SuspendingHelperRegistration(
            status: .requiresApproval
        )
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences
        )
        await controller.start()
        await controller.toggle(.lidClosed)
        XCTAssertEqual(
            controller.state[.lidClosed].intent,
            .waitingForApproval
        )

        helper.shouldSuspendNextStatus = true
        let refreshTask = Task {
            await controller.refreshExternalState()
        }
        await waitUntil { helper.isStatusSuspended }

        await controller.toggle(.lidClosed)
        helper.resumeStatus(with: .enabled)
        await refreshTask.value

        XCTAssertEqual(
            controller.state[.lidClosed].intent,
            .waitingForApproval
        )
        XCTAssertFalse(
            power.calls.contains(
                PowerCall(enabled: true, option: .lidClosed)
            )
        )
    }

    @Test
    func testInFlightEnablePersistsTargetAcrossShutdown() async {
        let power = SuspendingPowerController()
        let helper = MockHelperRegistration()
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences
        )
        await controller.start()

        power.callToSuspend = PowerCall(
            enabled: true,
            option: .displayOn
        )
        let toggleTask = Task {
            await controller.toggle(.displayOn)
        }
        await waitUntil { power.suspendedCall != nil }

        XCTAssertEqual(controller.state[.displayOn].intent, .enabled)
        XCTAssertTrue(
            preferences.value.enabledOptions.contains(.displayOn)
        )

        await controller.shutdown()
        power.resumeSuspendedCall()
        await toggleTask.value

        XCTAssertEqual(controller.state.lifecycle, .quitting)
        XCTAssertEqual(controller.state[.displayOn].intent, .enabled)
        XCTAssertTrue(
            preferences.value.enabledOptions.contains(.displayOn)
        )
        XCTAssertEqual(
            power.calls.filter { $0.option == .displayOn }.last,
            PowerCall(enabled: false, option: .displayOn)
        )
        XCTAssertGreaterThanOrEqual(
            power.calls.filter {
                $0 == PowerCall(
                    enabled: false,
                    option: .displayOn
                )
            }.count,
            2
        )
    }

    @Test
    func testInFlightDisablePersistsTargetAcrossShutdown() async {
        let power = SuspendingPowerController()
        let helper = MockHelperRegistration()
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences
        )
        await controller.start()
        await controller.toggle(.displayOn)

        power.callToSuspend = PowerCall(
            enabled: false,
            option: .displayOn
        )
        let toggleTask = Task {
            await controller.toggle(.displayOn)
        }
        await waitUntil { power.suspendedCall != nil }

        XCTAssertEqual(controller.state[.displayOn].intent, .off)
        XCTAssertFalse(
            preferences.value.enabledOptions.contains(.displayOn)
        )

        await controller.shutdown()
        power.resumeSuspendedCall()
        await toggleTask.value

        XCTAssertEqual(controller.state.lifecycle, .quitting)
        XCTAssertEqual(controller.state[.displayOn].intent, .off)
        XCTAssertFalse(
            preferences.value.enabledOptions.contains(.displayOn)
        )
    }

    @Test
    func testSecondToggleIsIgnoredWhileFirstTransitionIsInFlight() async {
        let power = SuspendingPowerController()
        let helper = MockHelperRegistration()
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences
        )
        await controller.start()

        power.callToSuspend = PowerCall(
            enabled: true,
            option: .displayOn
        )
        let firstToggle = Task {
            await controller.toggle(.displayOn)
        }
        await waitUntil { power.suspendedCall != nil }

        await controller.toggle(.displayOn)
        power.resumeSuspendedCall()
        await firstToggle.value

        XCTAssertEqual(
            power.calls,
            [PowerCall(enabled: true, option: .displayOn)]
        )
        XCTAssertEqual(controller.state[.displayOn].effect, .active)
    }

    @Test
    func testLostEffectSupersedesDelayedDisableCompletion() async {
        let power = SuspendingPowerController()
        let helper = MockHelperRegistration()
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences
        )
        await controller.start()
        await controller.toggle(.displayOn)

        power.callToSuspend = PowerCall(
            enabled: false,
            option: .displayOn
        )
        let disableTask = Task {
            await controller.toggle(.displayOn)
        }
        await waitUntil { power.suspendedCall != nil }

        controller.effectWasLost(.displayOn)
        power.resumeSuspendedCall()
        await disableTask.value

        XCTAssertEqual(controller.state[.displayOn].intent, .off)
        XCTAssertEqual(controller.state[.displayOn].effect, .inactive)
        XCTAssertEqual(
            controller.state[.displayOn].issue,
            .activationFailed
        )
        XCTAssertFalse(
            preferences.value.enabledOptions.contains(.displayOn)
        )
    }

    @Test
    func testLostEffectSupersedesDelayedLidActivation() async {
        let power = SuspendingPowerController()
        let helper = MockHelperRegistration(status: .enabled)
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences
        )
        await controller.start()

        power.callToSuspend = PowerCall(
            enabled: true,
            option: .lidClosed
        )
        let activationTask = Task {
            await controller.toggle(.lidClosed)
        }
        await waitUntil { power.suspendedCall != nil }
        XCTAssertEqual(controller.state[.lidClosed].effect, .applying)

        controller.effectWasLost(.lidClosed)
        power.resumeSuspendedCall()
        await activationTask.value

        XCTAssertEqual(
            controller.state[.lidClosed],
            WakeOptionState(
                intent: .off,
                effect: .inactive,
                issue: .helperConnectionLost
            )
        )
        XCTAssertEqual(
            power.calls,
            [
                PowerCall(enabled: true, option: .lidClosed),
            ]
        )
        XCTAssertFalse(
            preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testStaleActivationCannotDisableNewerRetry() async {
        let power = SuspendingPowerController()
        let helper = MockHelperRegistration(status: .enabled)
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences
        )
        await controller.start()

        power.callToSuspend = PowerCall(
            enabled: true,
            option: .lidClosed
        )
        let staleActivation = Task {
            await controller.toggle(.lidClosed)
        }
        await waitUntil { power.suspendedCall != nil }

        controller.effectWasLost(.lidClosed)
        await controller.toggle(.lidClosed)
        XCTAssertEqual(controller.state[.lidClosed].effect, .active)

        power.resumeSuspendedCall()
        await staleActivation.value

        XCTAssertEqual(
            controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertEqual(
            power.calls,
            [
                PowerCall(enabled: true, option: .lidClosed),
                PowerCall(enabled: true, option: .lidClosed),
            ]
        )
        XCTAssertTrue(
            preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testConnectionLossDuringExplicitLidDisableStaysOff() async {
        let power = SuspendingPowerController()
        let helper = MockHelperRegistration(status: .enabled)
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences
        )
        await controller.start()
        await controller.toggle(.lidClosed)

        power.callToSuspend = PowerCall(
            enabled: false,
            option: .lidClosed
        )
        let disableTask = Task {
            await controller.toggle(.lidClosed)
        }
        await waitUntil { power.suspendedCall != nil }

        controller.effectWasLost(.lidClosed)
        helper.statusValue = .requiresApproval
        power.resumeSuspendedCall()
        await disableTask.value
        await controller.refreshExternalState()

        XCTAssertEqual(
            controller.state[.lidClosed],
            WakeOptionState(
                intent: .off,
                effect: .inactive,
                issue: .helperUnavailable
            )
        )
        XCTAssertFalse(preferences.value.waitingForLidApproval)
        XCTAssertFalse(
            preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testLostEffectSupersedesDelayedStatusReconciliation() async {
        let power = SuspendingPowerController()
        let helper = MockHelperRegistration(status: .enabled)
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences
        )
        await controller.start()
        await controller.toggle(.lidClosed)

        power.callToSuspend = PowerCall(
            enabled: false,
            option: .lidClosed
        )
        helper.statusValue = .requiresApproval
        let refreshTask = Task {
            await controller.refreshExternalState()
        }
        await waitUntil { power.suspendedCall != nil }
        XCTAssertEqual(controller.state[.lidClosed].effect, .removing)

        controller.effectWasLost(.lidClosed)
        power.resumeSuspendedCall()
        await refreshTask.value

        XCTAssertEqual(
            controller.state[.lidClosed],
            WakeOptionState(
                intent: .waitingForApproval,
                effect: .inactive
            )
        )
        XCTAssertTrue(preferences.value.waitingForLidApproval)
        XCTAssertEqual(
            power.calls,
            [
                PowerCall(enabled: true, option: .lidClosed),
                PowerCall(enabled: false, option: .lidClosed),
            ]
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: () -> Bool,
        iterations: Int = 1_000
    ) async {
        for _ in 0..<iterations {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous test condition")
    }
}
