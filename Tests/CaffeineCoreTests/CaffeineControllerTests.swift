import Testing
@testable import CaffeineCore

@Suite("Caffeine controller")
@MainActor
struct CaffeineControllerTests {
    @Test
    func testStartWithEmptyPreferencesProducesRunningInactiveState() async {
        let fixture = makeFixture()

        await fixture.controller.start()

        XCTAssertEqual(fixture.controller.state.lifecycle, .running)
        XCTAssertFalse(fixture.controller.state.hasActiveWakeOption)
        XCTAssertEqual(fixture.power.calls, [])
        XCTAssertEqual(fixture.helper.statusCallCount, 1)
        XCTAssertEqual(fixture.launchAtLogin.statusCallCount, 1)
    }

    @Test
    func testStartReappliesPersistedIndependentOptions() async {
        let fixture = makeFixture(
            storedPreferences: StoredPreferences(
                enabledOptions: [.displayOn, .screenSaver]
            )
        )

        await fixture.controller.start()

        XCTAssertEqual(
            fixture.power.calls,
            [
                PowerCall(enabled: true, option: .displayOn),
                PowerCall(enabled: true, option: .screenSaver),
            ]
        )
        XCTAssertEqual(fixture.controller.state[.displayOn].effect, .active)
        XCTAssertEqual(fixture.controller.state[.screenSaver].effect, .active)
        XCTAssertEqual(fixture.controller.state[.lidClosed].effect, .inactive)
        XCTAssertEqual(
            fixture.preferences.value.enabledOptions,
            [.displayOn, .screenSaver]
        )
    }

    @Test
    func testFreshControllerRestoresAllEnabledOptionsAfterRestart() async {
        let firstRun = makeFixture(helperStatus: .enabled)
        await firstRun.controller.start()
        await firstRun.controller.toggleAll()

        XCTAssertEqual(
            firstRun.preferences.value.enabledOptions,
            Set(WakeOption.allCases)
        )

        await firstRun.controller.shutdown()
        let restarted = makeFixture(
            storedPreferences: firstRun.preferences.value,
            helperStatus: .enabled
        )

        await restarted.controller.start()

        XCTAssertEqual(
            restarted.power.calls,
            [
                PowerCall(enabled: true, option: .displayOn),
                PowerCall(enabled: true, option: .screenSaver),
                PowerCall(enabled: true, option: .lidClosed),
            ]
        )
        for option in WakeOption.allCases {
            XCTAssertEqual(
                restarted.controller.state[option],
                WakeOptionState(intent: .enabled, effect: .active)
            )
        }
        XCTAssertEqual(
            restarted.preferences.value.enabledOptions,
            Set(WakeOption.allCases)
        )
    }

    @Test
    func testRestoreFailureRollsBackOnlyFailingOption() async {
        let fixture = makeFixture(
            storedPreferences: StoredPreferences(
                enabledOptions: [.displayOn, .screenSaver]
            )
        )
        fixture.power.failNext(enabled: true, option: .displayOn)

        await fixture.controller.start()

        XCTAssertEqual(
            fixture.controller.state[.displayOn],
            WakeOptionState(
                intent: .off,
                effect: .inactive,
                issue: .activationFailed
            )
        )
        XCTAssertEqual(
            fixture.controller.state[.screenSaver],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertEqual(
            fixture.preferences.value.enabledOptions,
            [.screenSaver]
        )
    }

    @Test
    func testStartIsIdempotent() async {
        let fixture = makeFixture(
            storedPreferences: StoredPreferences(
                enabledOptions: [.displayOn]
            )
        )

        await fixture.controller.start()
        let callsAfterFirstStart = fixture.power.calls
        let helperCallsAfterFirstStart = fixture.helper.statusCallCount

        await fixture.controller.start()

        XCTAssertEqual(fixture.power.calls, callsAfterFirstStart)
        XCTAssertEqual(
            fixture.helper.statusCallCount,
            helperCallsAfterFirstStart
        )
    }

    @Test
    func testIndependentTogglesDoNotAffectOtherOptions() async {
        let fixture = makeFixture()
        await fixture.controller.start()

        await fixture.controller.toggle(.displayOn)
        await fixture.controller.toggle(.screenSaver)
        await fixture.controller.toggle(.displayOn)

        XCTAssertEqual(fixture.controller.state[.displayOn].intent, .off)
        XCTAssertEqual(fixture.controller.state[.displayOn].effect, .inactive)
        XCTAssertEqual(fixture.controller.state[.screenSaver].intent, .enabled)
        XCTAssertEqual(fixture.controller.state[.screenSaver].effect, .active)
        XCTAssertEqual(
            fixture.preferences.value.enabledOptions,
            [.screenSaver]
        )
        XCTAssertEqual(
            fixture.power.calls,
            [
                PowerCall(enabled: true, option: .displayOn),
                PowerCall(enabled: true, option: .screenSaver),
                PowerCall(enabled: false, option: .displayOn),
            ]
        )
    }

    @Test
    func testEnableFailureRollsBackAndCanBeRetried() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        fixture.power.failNext(enabled: true, option: .displayOn)

        await fixture.controller.toggle(.displayOn)

        XCTAssertEqual(fixture.controller.state[.displayOn].intent, .off)
        XCTAssertEqual(
            fixture.controller.state[.displayOn].issue,
            .activationFailed
        )
        XCTAssertFalse(
            fixture.preferences.value.enabledOptions.contains(.displayOn)
        )

        await fixture.controller.toggle(.displayOn)

        XCTAssertEqual(fixture.controller.state[.displayOn].intent, .enabled)
        XCTAssertEqual(fixture.controller.state[.displayOn].effect, .active)
        XCTAssertNil(fixture.controller.state[.displayOn].issue)
    }

    @Test
    func testDisableFailureKeepsOptionVisiblyEnabled() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        await fixture.controller.toggle(.displayOn)
        fixture.power.failNext(enabled: false, option: .displayOn)

        await fixture.controller.toggle(.displayOn)

        XCTAssertEqual(fixture.controller.state[.displayOn].intent, .enabled)
        XCTAssertEqual(fixture.controller.state[.displayOn].effect, .active)
        XCTAssertEqual(
            fixture.controller.state[.displayOn].issue,
            .deactivationFailed
        )
        XCTAssertTrue(
            fixture.preferences.value.enabledOptions.contains(.displayOn)
        )
    }

    @Test
    func testLostOwnershipDuringDisableFailsClosed() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()
        await fixture.controller.toggle(.lidClosed)
        fixture.power.failNext(
            enabled: false,
            option: .lidClosed,
            error: PowerEffectStateError.noLongerControlled
        )

        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(fixture.controller.state[.lidClosed].intent, .off)
        XCTAssertEqual(fixture.controller.state[.lidClosed].effect, .inactive)
        XCTAssertEqual(
            fixture.controller.state[.lidClosed].issue,
            .helperUnavailable
        )
        XCTAssertFalse(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testLostEffectRollsBackSelectionAndPersists() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        await fixture.controller.toggle(.screenSaver)

        fixture.controller.effectWasLost(.screenSaver)

        XCTAssertEqual(
            fixture.controller.state[.screenSaver],
            WakeOptionState(
                intent: .off,
                effect: .inactive,
                issue: .activationFailed
            )
        )
        XCTAssertFalse(
            fixture.preferences.value.enabledOptions.contains(.screenSaver)
        )
    }

    @Test
    func testLostActiveLidEffectRecordsUnexpectedConnectionLoss() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()
        await fixture.controller.toggle(.lidClosed)

        fixture.controller.effectWasLost(
            .lidClosed,
            issue: .deactivationFailed
        )

        XCTAssertEqual(fixture.controller.state[.lidClosed].intent, .off)
        XCTAssertEqual(
            fixture.controller.state[.lidClosed].issue,
            .helperConnectionLost
        )
    }

    @Test
    func testLostEffectIsIgnoredWhenInactiveOrQuitting() async {
        let fixture = makeFixture()
        await fixture.controller.start()

        fixture.controller.effectWasLost(.displayOn)
        XCTAssertEqual(
            fixture.controller.state[.displayOn],
            WakeOptionState()
        )

        await fixture.controller.toggle(.displayOn)
        await fixture.controller.shutdown()
        let stateAfterShutdown = fixture.controller.state[.displayOn]

        fixture.controller.effectWasLost(.displayOn)

        XCTAssertEqual(
            fixture.controller.state[.displayOn],
            stateAfterShutdown
        )
    }

    @Test
    func testStateObserverSeesApplyingAndStableStates() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        var observedEffects: [EffectStatus] = []
        fixture.controller.onStateChange = {
            observedEffects.append($0[.displayOn].effect)
        }

        await fixture.controller.toggle(.displayOn)

        XCTAssertTrue(observedEffects.contains(.applying))
        XCTAssertEqual(observedEffects.last, .active)
    }

    @Test
    func testLidEnableRegistersLazilyThenActivates() async {
        let fixture = makeFixture(
            helperStatus: .notRegistered,
            helperReadiness: .ready,
            helperStatusAfterEnsure: .enabled
        )
        await fixture.controller.start()
        var events: [CaffeineControllerEvent] = []
        fixture.controller.onEvent = { events.append($0) }

        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(fixture.helper.ensureCallCount, 1)
        XCTAssertEqual(
            fixture.power.calls,
            [PowerCall(enabled: true, option: .lidClosed)]
        )
        XCTAssertEqual(fixture.controller.state.helperStatus, .enabled)
        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertTrue(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testFirstApprovalRequestIsPersistedUncheckedAndEmitsOneEvent() async {
        let fixture = makeFixture(helperStatus: .requiresApproval)
        await fixture.controller.start()
        var events: [CaffeineControllerEvent] = []
        fixture.controller.onEvent = { events.append($0) }

        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(
            fixture.controller.state[.lidClosed].intent,
            .waitingForApproval
        )
        XCTAssertEqual(
            fixture.controller.state[.lidClosed].effect,
            .inactive
        )
        XCTAssertEqual(
            events,
            [.requestHelperApproval(showExplanation: true)]
        )
        XCTAssertTrue(fixture.preferences.value.waitingForLidApproval)
        XCTAssertTrue(fixture.preferences.value.didExplainHelperApproval)
        XCTAssertFalse(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )

        await fixture.controller.toggle(.lidClosed)
        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(
            events,
            [
                .requestHelperApproval(showExplanation: true),
                .requestHelperApproval(showExplanation: false),
                .requestHelperApproval(showExplanation: false),
            ]
        )
    }

    @Test
    func testClickingPendingLidRequestRechecksAndOpensApproval() async {
        let fixture = makeFixture(helperStatus: .requiresApproval)
        await fixture.controller.start()
        var events: [CaffeineControllerEvent] = []
        fixture.controller.onEvent = { events.append($0) }
        await fixture.controller.toggle(.lidClosed)

        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(
            fixture.controller.state[.lidClosed].intent,
            .waitingForApproval
        )
        XCTAssertTrue(fixture.preferences.value.waitingForLidApproval)
        XCTAssertEqual(
            events,
            [
                .requestHelperApproval(showExplanation: true),
                .requestHelperApproval(showExplanation: false),
            ]
        )

        fixture.helper.statusValue = .enabled
        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertEqual(
            fixture.power.calls,
            [PowerCall(enabled: true, option: .lidClosed)]
        )
    }

    @Test
    func testPendingApprovalCompletesAutomaticallyOnRefresh() async {
        let fixture = makeFixture(helperStatus: .requiresApproval)
        await fixture.controller.start()
        await fixture.controller.toggle(.lidClosed)
        fixture.helper.statusValue = .enabled

        await fixture.controller.refreshExternalState()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertFalse(fixture.preferences.value.waitingForLidApproval)
        XCTAssertTrue(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )
        XCTAssertEqual(
            fixture.power.calls,
            [PowerCall(enabled: true, option: .lidClosed)]
        )
    }

    @Test
    func testPersistedPendingApprovalCompletesOnStartWithoutModal() async {
        let fixture = makeFixture(
            storedPreferences: StoredPreferences(
                waitingForLidApproval: true,
                didExplainHelperApproval: true
            ),
            helperStatus: .enabled
        )
        var events: [CaffeineControllerEvent] = []
        fixture.controller.onEvent = { events.append($0) }

        await fixture.controller.start()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertEqual(events, [])
    }

    @Test
    func testApprovalRevocationRevertsLidToQuietWaitingState() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()
        await fixture.controller.toggle(.lidClosed)
        fixture.helper.statusValue = .requiresApproval

        await fixture.controller.refreshExternalState()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(
                intent: .waitingForApproval,
                effect: .inactive
            )
        )
        XCTAssertTrue(fixture.preferences.value.waitingForLidApproval)
        XCTAssertFalse(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )
        XCTAssertEqual(
            fixture.power.calls,
            [
                PowerCall(enabled: true, option: .lidClosed),
                PowerCall(enabled: false, option: .lidClosed),
            ]
        )
    }

    @Test
    func testApprovalStatusAfterConnectionLossRestoresPendingIntent() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()
        await fixture.controller.toggle(.lidClosed)

        fixture.controller.effectWasLost(.lidClosed)
        fixture.helper.statusValue = .requiresApproval
        await fixture.controller.refreshExternalState()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(
                intent: .waitingForApproval,
                effect: .inactive
            )
        )
        XCTAssertTrue(fixture.preferences.value.waitingForLidApproval)
    }

    @Test
    func testPendingApprovalRetriesTransientUnknownStatus() async {
        let power = MockPowerController()
        let helper = MockHelperRegistration(status: .requiresApproval)
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore()
        var observedDelays: [Duration] = []
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences,
            sleepBeforeLidRestoreRetry: { delay in
                observedDelays.append(delay)
                helper.statusValue = .enabled
            }
        )
        await controller.start()
        await controller.toggle(.lidClosed)
        helper.statusValue = .unknown

        await controller.refreshExternalState()

        XCTAssertEqual(observedDelays, [.milliseconds(250)])
        XCTAssertEqual(
            controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertEqual(
            power.calls,
            [PowerCall(enabled: true, option: .lidClosed)]
        )
        XCTAssertFalse(preferences.value.waitingForLidApproval)
        XCTAssertTrue(
            preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testApprovalStatusAfterExplicitDisableOwnershipLossStaysOff() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()
        await fixture.controller.toggle(.lidClosed)
        fixture.power.failNext(
            enabled: false,
            option: .lidClosed,
            error: PowerEffectStateError.noLongerControlled
        )

        await fixture.controller.toggle(.lidClosed)
        fixture.helper.statusValue = .requiresApproval
        await fixture.controller.refreshExternalState()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(
                intent: .off,
                effect: .inactive,
                issue: .helperUnavailable
            )
        )
        XCTAssertFalse(fixture.preferences.value.waitingForLidApproval)
        XCTAssertFalse(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testActiveLidHelperLossExplicitlyClearsBeforeGoingOff() async {
        let cases: [(ServiceStatus, OptionIssue)] = [
            (.notRegistered, .helperUnavailable),
            (.notFound, .helperNotFound),
        ]

        for (status, expectedIssue) in cases {
            let fixture = makeFixture(helperStatus: .enabled)
            await fixture.controller.start()
            await fixture.controller.toggle(.lidClosed)
            fixture.helper.statusValue = status

            await fixture.controller.refreshExternalState()

            XCTAssertEqual(
                fixture.controller.state[.lidClosed],
                WakeOptionState(
                    intent: .off,
                    effect: .inactive,
                    issue: expectedIssue
                )
            )
            XCTAssertEqual(
                fixture.power.calls,
                [
                    PowerCall(enabled: true, option: .lidClosed),
                    PowerCall(enabled: false, option: .lidClosed),
                ]
            )
            XCTAssertFalse(
                fixture.preferences.value.enabledOptions.contains(.lidClosed)
            )
        }
    }

    @Test
    func testLidXPCFailureRollsBackWithRetryHint() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()
        fixture.power.failNext(enabled: true, option: .lidClosed)

        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(fixture.controller.state[.lidClosed].intent, .off)
        XCTAssertEqual(
            fixture.controller.state[.lidClosed].issue,
            .helperUnavailable
        )
        XCTAssertFalse(fixture.preferences.value.waitingForLidApproval)
    }

    @Test
    func testRestoredLidIntentSurvivesTransientUnavailableStatus() async {
        let fixture = makeFixture(
            storedPreferences: StoredPreferences(
                enabledOptions: [.lidClosed]
            ),
            helperStatus: .unknown
        )

        await fixture.controller.start()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(
                intent: .enabled,
                effect: .inactive,
                issue: .helperUnavailable
            )
        )
        XCTAssertTrue(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )
        XCTAssertEqual(fixture.power.calls, [])

        fixture.helper.statusValue = .enabled
        await fixture.controller.refreshExternalState()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertEqual(
            fixture.power.calls,
            [PowerCall(enabled: true, option: .lidClosed)]
        )
    }

    @Test
    func testRestoredLidIntentRetriesAutomaticallyAfterStartupRace() async {
        let power = MockPowerController()
        let helper = MockHelperRegistration(status: .unknown)
        let launchAtLogin = MockLaunchAtLoginManager()
        let preferences = MockPreferencesStore(
            StoredPreferences(enabledOptions: [.lidClosed])
        )
        var observedDelays: [Duration] = []
        let controller = CaffeineController(
            powerController: power,
            helperRegistration: helper,
            launchAtLoginManager: launchAtLogin,
            preferencesStore: preferences,
            sleepBeforeLidRestoreRetry: { delay in
                observedDelays.append(delay)
                helper.statusValue = .enabled
            }
        )

        await controller.start()

        XCTAssertEqual(observedDelays, [.milliseconds(250)])
        XCTAssertEqual(
            controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertEqual(
            power.calls,
            [PowerCall(enabled: true, option: .lidClosed)]
        )
        XCTAssertTrue(
            preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testRestoredLidIntentRetriesTransientXPCStartupFailure() async {
        let fixture = makeFixture(
            storedPreferences: StoredPreferences(
                enabledOptions: [.lidClosed]
            ),
            helperStatus: .enabled
        )
        fixture.power.failNext(enabled: true, option: .lidClosed)

        await fixture.controller.start()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertTrue(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )
        XCTAssertEqual(
            fixture.power.calls,
            [
                PowerCall(enabled: true, option: .lidClosed),
                PowerCall(enabled: true, option: .lidClosed),
            ]
        )
    }

    @Test
    func testTransientUnknownStatusDoesNotClearActiveLidIntent() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()
        await fixture.controller.toggle(.lidClosed)
        fixture.helper.statusValue = .unknown

        await fixture.controller.refreshExternalState()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertEqual(
            fixture.power.calls,
            [PowerCall(enabled: true, option: .lidClosed)]
        )
        XCTAssertTrue(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testRestoredLidIntentFailsOffForDefinitiveHelperProblems() async {
        let cases: [(HelperReadiness, OptionIssue)] = [
            (.requiresInstallation, .helperRequiresInstallation),
            (.missing, .helperNotFound),
        ]

        for (readiness, expectedIssue) in cases {
            let fixture = makeFixture(
                storedPreferences: StoredPreferences(
                    enabledOptions: [.lidClosed]
                ),
                helperStatus: .notFound,
                helperReadiness: readiness,
                helperStatusAfterEnsure: .notFound
            )

            await fixture.controller.start()

            XCTAssertEqual(
                fixture.controller.state[.lidClosed],
                WakeOptionState(
                    intent: .off,
                    effect: .inactive,
                    issue: expectedIssue
                )
            )
            XCTAssertFalse(
                fixture.preferences.value.enabledOptions.contains(.lidClosed)
            )
            XCTAssertFalse(fixture.preferences.value.waitingForLidApproval)
        }
    }

    @Test
    func testMissingServiceRecordRegistersAndPresentsApproval() async {
        let fixture = makeFixture(
            helperStatus: .notFound,
            helperReadiness: .requiresApproval,
            helperStatusAfterEnsure: .requiresApproval
        )
        await fixture.controller.start()
        var events: [CaffeineControllerEvent] = []
        fixture.controller.onEvent = { events.append($0) }

        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(fixture.helper.ensureCallCount, 1)
        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(
                intent: .waitingForApproval,
                effect: .inactive
            )
        )
        XCTAssertEqual(
            events,
            [.requestHelperApproval(showExplanation: true)]
        )
        XCTAssertEqual(fixture.power.calls, [])
    }

    @Test
    func testUnreadableEmbeddedHelperIsReportedAsMissing() async {
        let fixture = makeFixture(
            helperStatus: .notFound,
            helperReadiness: .missing,
            helperStatusAfterEnsure: .notFound
        )
        await fixture.controller.start()

        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(fixture.helper.ensureCallCount, 1)
        XCTAssertEqual(
            fixture.controller.state[.lidClosed].issue,
            .helperNotFound
        )
        XCTAssertEqual(fixture.power.calls, [])
    }

    @Test
    func testMissingLocalHelperPresentsInstallationInstructions() async {
        let fixture = makeFixture(
            helperStatus: .notFound,
            helperReadiness: .requiresInstallation,
            helperStatusAfterEnsure: .notFound
        )
        await fixture.controller.start()
        var events: [CaffeineControllerEvent] = []
        fixture.controller.onEvent = { events.append($0) }

        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(fixture.helper.ensureCallCount, 1)
        XCTAssertEqual(
            fixture.controller.state[.lidClosed].issue,
            .helperRequiresInstallation
        )
        XCTAssertEqual(
            fixture.controller.state.menuPresentation
                .optionItems[.lidClosed]?.subtitle,
            "Install helper to enable"
        )
        XCTAssertEqual(fixture.power.calls, [])
        XCTAssertEqual(events, [.presentHelperInstallationRequired])
    }

    @Test
    func testHelperInstallationHandoffDurablyDefersLidRequest() async {
        let fixture = makeFixture(
            helperStatus: .notFound,
            helperReadiness: .requiresInstallation,
            helperStatusAfterEnsure: .notFound
        )
        await fixture.controller.start()
        await fixture.controller.toggle(.lidClosed)

        fixture.controller.deferLidRequestForHelperInstallation()

        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(
                intent: .waitingForApproval,
                effect: .inactive
            )
        )
        XCTAssertTrue(fixture.preferences.value.waitingForLidApproval)
        XCTAssertFalse(
            fixture.preferences.value.enabledOptions.contains(.lidClosed)
        )

        let saveCount = fixture.preferences.savedValues.count
        fixture.controller.deferLidRequestForHelperInstallation()
        XCTAssertEqual(fixture.preferences.savedValues.count, saveCount)

        await fixture.controller.shutdown()
        let reopened = makeFixture(
            storedPreferences: fixture.preferences.value,
            helperStatus: .enabled
        )

        await reopened.controller.start()

        XCTAssertEqual(
            reopened.controller.state[.lidClosed],
            WakeOptionState(intent: .enabled, effect: .active)
        )
        XCTAssertEqual(
            reopened.power.calls,
            [PowerCall(enabled: true, option: .lidClosed)]
        )
        XCTAssertFalse(reopened.preferences.value.waitingForLidApproval)
        XCTAssertTrue(
            reopened.preferences.value.enabledOptions.contains(.lidClosed)
        )
    }

    @Test
    func testLidOutsideApplicationsShowsActionableMoveHint() async {
        let fixture = makeFixture(
            helperStatus: .notRegistered,
            helperReadiness: .moveToApplications,
            helperStatusAfterEnsure: .notRegistered
        )
        await fixture.controller.start()

        await fixture.controller.toggle(.lidClosed)

        XCTAssertEqual(fixture.helper.ensureCallCount, 1)
        XCTAssertEqual(
            fixture.controller.state[.lidClosed],
            WakeOptionState(
                intent: .off,
                effect: .inactive,
                issue: .moveToApplications
            )
        )
        XCTAssertEqual(
            fixture.controller.state.menuPresentation
                .optionItems[.lidClosed]?.subtitle,
            "Move Caffeine to /Applications"
        )
        XCTAssertEqual(fixture.power.calls, [])
    }

    @Test
    func testEnableAllActivatesEveryOption() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()

        await fixture.controller.toggleAll()

        for option in WakeOption.allCases {
            XCTAssertEqual(
                fixture.controller.state[option],
                WakeOptionState(intent: .enabled, effect: .active)
            )
        }
        XCTAssertEqual(
            fixture.preferences.value.enabledOptions,
            Set(WakeOption.allCases)
        )
    }

    @Test
    func testEnableAllKeepsIndependentSuccessesWhenOneFails() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()
        fixture.power.failNext(enabled: true, option: .screenSaver)

        await fixture.controller.toggleAll()

        XCTAssertEqual(fixture.controller.state[.displayOn].effect, .active)
        XCTAssertEqual(fixture.controller.state[.screenSaver].effect, .inactive)
        XCTAssertEqual(
            fixture.controller.state[.screenSaver].issue,
            .activationFailed
        )
        XCTAssertEqual(fixture.controller.state[.lidClosed].effect, .active)
        XCTAssertEqual(
            fixture.preferences.value.enabledOptions,
            [.displayOn, .lidClosed]
        )
    }

    @Test
    func testEnableAllLeavesLidPendingWhileOtherOptionsActivate() async {
        let fixture = makeFixture(helperStatus: .requiresApproval)
        await fixture.controller.start()

        await fixture.controller.toggleAll()

        XCTAssertEqual(fixture.controller.state[.displayOn].effect, .active)
        XCTAssertEqual(fixture.controller.state[.screenSaver].effect, .active)
        XCTAssertEqual(
            fixture.controller.state[.lidClosed].intent,
            .waitingForApproval
        )
        XCTAssertEqual(fixture.controller.state[.lidClosed].effect, .inactive)
    }

    @Test
    func testDisableAllAttemptsEveryActiveOptionAfterFailure() async {
        let fixture = makeFixture(helperStatus: .enabled)
        await fixture.controller.start()
        await fixture.controller.toggleAll()
        fixture.power.failNext(enabled: false, option: .screenSaver)

        await fixture.controller.toggleAll()

        XCTAssertEqual(fixture.controller.state[.lidClosed].intent, .off)
        XCTAssertEqual(fixture.controller.state[.displayOn].intent, .off)
        XCTAssertEqual(fixture.controller.state[.screenSaver].intent, .enabled)
        XCTAssertEqual(
            fixture.controller.state[.screenSaver].issue,
            .deactivationFailed
        )
        XCTAssertEqual(
            Array(fixture.power.calls.suffix(3)),
            [
                PowerCall(enabled: false, option: .lidClosed),
                PowerCall(enabled: false, option: .screenSaver),
                PowerCall(enabled: false, option: .displayOn),
            ]
        )
    }

    @Test
    func testDisableAllCancelsPendingLidRequest() async {
        let fixture = makeFixture(helperStatus: .requiresApproval)
        await fixture.controller.start()
        await fixture.controller.toggle(.displayOn)
        await fixture.controller.toggle(.lidClosed)

        await fixture.controller.toggleAll()

        XCTAssertEqual(fixture.controller.state[.displayOn].intent, .off)
        XCTAssertEqual(fixture.controller.state[.lidClosed].intent, .off)
        XCTAssertFalse(fixture.preferences.value.waitingForLidApproval)
    }

    @Test
    func testShutdownAttemptsAllCleanupAndPreservesPreferences() async {
        let fixture = makeFixture()
        await fixture.controller.start()
        await fixture.controller.toggle(.displayOn)
        let durableValue = fixture.preferences.value
        let saveCount = fixture.preferences.savedValues.count
        fixture.power.failNext(enabled: false, option: .screenSaver)

        await fixture.controller.shutdown()

        XCTAssertEqual(fixture.controller.state.lifecycle, .quitting)
        XCTAssertEqual(fixture.preferences.value, durableValue)
        XCTAssertEqual(fixture.preferences.savedValues.count, saveCount)
        XCTAssertEqual(
            Array(fixture.power.calls.suffix(3)),
            [
                PowerCall(enabled: false, option: .lidClosed),
                PowerCall(enabled: false, option: .screenSaver),
                PowerCall(enabled: false, option: .displayOn),
            ]
        )
        XCTAssertEqual(
            fixture.controller.state[.displayOn].intent,
            .enabled
        )
        XCTAssertEqual(
            fixture.controller.state[.displayOn].effect,
            .inactive
        )
    }

    @Test
    func testShutdownIsIdempotentAndRejectsLaterActions() async {
        let fixture = makeFixture()
        await fixture.controller.start()

        await fixture.controller.shutdown()
        let callsAfterShutdown = fixture.power.calls
        await fixture.controller.shutdown()
        await fixture.controller.toggle(.displayOn)
        await fixture.controller.toggleAll()
        await fixture.controller.toggleLaunchAtLogin()

        XCTAssertEqual(fixture.power.calls, callsAfterShutdown)
        XCTAssertEqual(fixture.launchAtLogin.registerCallCount, 0)
        XCTAssertEqual(fixture.launchAtLogin.unregisterCallCount, 0)
    }
}
