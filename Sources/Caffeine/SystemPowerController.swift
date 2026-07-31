import CaffeineCore
import CaffeineIPC
import Foundation
import IOKit.pwr_mgt
import OSLog

enum PowerControlError: LocalizedError {
    case ioKit(operation: String, result: IOReturn)
    case helperUnavailable
    case helperRejectedRequest
    case helperTimedOut
    case lidDisplayObservationTimedOut
    case lidDisplayObservationFailed(String)
    case displaySleepCommandFailed(
        status: Int32,
        standardError: String
    )
    case displaySleepNotConfirmed(String)
    case operationSuperseded

    var errorDescription: String? {
        switch self {
        case let .ioKit(operation, result):
            return "\(operation) failed with IOKit result 0x\(String(result, radix: 16))"
        case .helperUnavailable:
            return "The privileged helper is unavailable."
        case .helperRejectedRequest:
            return "The privileged helper could not change the sleep setting."
        case .helperTimedOut:
            return "The privileged helper did not respond."
        case .lidDisplayObservationTimedOut:
            return "Caffeine could not determine the current lid and display state."
        case let .lidDisplayObservationFailed(message):
            return "Caffeine lost the lid/display observation: \(message)"
        case let .displaySleepCommandFailed(status, standardError):
            let detail = standardError.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if detail.isEmpty {
                return """
                    Requesting display sleep failed with status \(status).
                    """
            }
            return """
                Requesting display sleep failed with status \(status): \
                \(detail)
                """
        case let .displaySleepNotConfirmed(detail):
            return """
                macOS did not confirm that the built-in display went to \
                sleep: \(detail)
                """
        case .operationSuperseded:
            return "The power operation was superseded."
        }
    }
}

actor SystemPowerController: PowerControlling {
    typealias EffectLostHandler =
        @MainActor @Sendable (WakeOption, OptionIssue) -> Void

    private enum DisplaySleepCompletion {
        case result(DisplaySleepCommandResult)
        case failure(String)
    }

    private static let displayReason =
        "Caffeine is keeping the display awake"
    private static let systemAwakeReason =
        "Caffeine is keeping the Mac awake"
    private static let screenSaverReason =
        "Caffeine is preventing the screen saver"
    private static let lateDisplayWakeReason =
        "Caffeine is preserving an attached external display"
    private static let conservativeUnknownLidEnvironment =
        LidDisplayEnvironmentState(
            clamshellState: .closed,
            hasOnlineExternalDisplay: false
        )
    private let logger: Logger
    private let lidDisplayEnvironmentObserver:
        any LidDisplayEnvironmentObserving
    private let displaySleepRequester: any DisplaySleepRequesting
    private let builtInDisplaySleepReader:
        any BuiltInDisplaySleepReading
    private let lidHelperClientFactory:
        any LidHelperLeaseClientFactory
    private let powerAssertionBackend:
        any PowerAssertionBackend
    private let timing: SystemPowerControllerTiming

    private var displayOnIsEnabled = false
    private var displayAssertion: IOPMAssertionID?
    private var systemAwakeAssertion: IOPMAssertionID?
    private var activityAssertion: IOPMAssertionID?
    private var screenSaverPreventionIsEnabled = false
    private var screenSaverTask: Task<Void, Never>?

    private var lidConnection: (any LidHelperLeaseClient)?
    private var lidConnectionIdentifier: UUID?
    private var lidSessionIdentifier: UUID?
    private var lidIsEnabled = false
    private var lidRecoveryTask: Task<Void, Never>?
    private var lidRecoveryIdentifier: UUID?
    private var lidRecoveryCleanupSessionIdentifier: UUID?
    /// The menu option is already off, but the helper has not yet confirmed
    /// that persistent `SleepDisabled` is false. While this is true, display
    /// effects follow the observed topology instead of being unconditionally
    /// restored: a closed/headless Mac stays suppressed until recovery.
    private var lidCleanupAwaitingHelperClear = false
    private var lidCleanupSessionIdentifier: UUID?

    private var lidDisplayPolicy = LidDisplayPolicyCoordinator()
    private var lidObservationIdentifier: UUID?
    private var lidObservationEventContinuation:
        AsyncStream<LidDisplayEnvironmentEvent>.Continuation?
    private var lidObservationEventTask: Task<Void, Never>?
    private var lidEnvironmentState: LidDisplayEnvironmentState?
    private var lidEnvironmentIsValid = false
    private var lidObservationFailureDescription: String?
    private var initialLidEnvironmentWaiter: (
        identifier: UUID,
        continuation:
            CheckedContinuation<LidDisplayEnvironmentState, Error>
    )?
    private var initialLidEnvironmentTimeoutTask:
        Task<Void, Never>?
    private var displayConfigurationTimeoutTask:
        Task<Void, Never>?
    private var displaySleepTasks: [
        LidDisplayPolicyGeneration: Task<Void, Never>
    ] = [:]
    private var displaySleepTimeoutTasks: [
        LidDisplayPolicyGeneration: Task<Void, Never>
    ] = [:]
    private var pendingLateDisplayWake: (
        sessionIdentifier: UUID,
        generation: LidDisplayPolicyGeneration
    )?
    private var lidPolicyFailureInProgress = false

    private var effectLostHandler: EffectLostHandler?

    init(
        lidDisplayEnvironmentObserver:
            any LidDisplayEnvironmentObserving =
                MacLidDisplayEnvironmentObserver(),
        displaySleepRequester:
            any DisplaySleepRequesting =
                PMSetDisplaySleepRequester(),
        builtInDisplaySleepReader:
            any BuiltInDisplaySleepReading =
                CoreGraphicsBuiltInDisplaySleepReader(),
        lidHelperClientFactory:
            (any LidHelperLeaseClientFactory)? = nil,
        powerAssertionBackend:
            any PowerAssertionBackend =
                IOKitPowerAssertionBackend(),
        timing: SystemPowerControllerTiming = .production,
        logger: Logger = Logger(
            subsystem: CaffeineIPC.applicationIdentifier,
            category: "Power"
        )
    ) {
        self.lidDisplayEnvironmentObserver =
            lidDisplayEnvironmentObserver
        self.displaySleepRequester = displaySleepRequester
        self.builtInDisplaySleepReader =
            builtInDisplaySleepReader
        self.lidHelperClientFactory =
            lidHelperClientFactory
            ?? XPCLidHelperLeaseClientFactory(
                logger: logger
            )
        self.powerAssertionBackend = powerAssertionBackend
        self.timing = timing
        self.logger = logger
    }

    func setEffectLostHandler(
        _ handler: EffectLostHandler?
    ) {
        effectLostHandler = handler
    }

#if DEBUG
    /// Lets the hermetic controller tests establish that an asynchronously
    /// delivered observer event has crossed the controller's event stream.
    func observedLidFailureForTesting() -> String? {
        lidObservationFailureDescription
    }

    func observedLidEnvironmentForTesting()
        -> LidDisplayEnvironmentState?
    {
        lidEnvironmentState
    }
#endif

    func setEnabled(
        _ enabled: Bool,
        for option: WakeOption
    ) async throws {
        switch option {
        case .systemAwake:
            try setSystemAwake(enabled)
        case .displayOn:
            try setDisplayOn(enabled)
        case .screenSaver:
            try setScreenSaverPrevention(enabled)
        case .lidClosed:
            try await setLidSleepDisabled(enabled)
        }
    }

    private func setSystemAwake(_ enabled: Bool) throws {
        if enabled {
            guard systemAwakeAssertion == nil else {
                return
            }

            systemAwakeAssertion = try createNamedAssertion(
                kind: .preventUserIdleSystemSleep,
                reason: Self.systemAwakeReason,
                operationName: "system-awake"
            )
            logger.info(
                "Enabled system sleep prevention while allowing display sleep"
            )
            return
        }

        guard let identifier = systemAwakeAssertion else {
            return
        }

        try releaseAssertion(
            identifier,
            operationName: "system-awake"
        )
        systemAwakeAssertion = nil
        logger.info(
            "Disabled system sleep prevention that allows display sleep"
        )
    }

    private func setDisplayOn(_ enabled: Bool) throws {
        if enabled {
            guard !displayOnIsEnabled else {
                return
            }

            displayOnIsEnabled = true
            do {
                if !lidDisplayPolicy.state
                    .caffeineDisplayEffectsAreSuspended {
                    try activateDisplayOnEffect()
                }
            } catch {
                displayOnIsEnabled = false
                throw error
            }
            if lidDisplayPolicy.state
                .caffeineDisplayEffectsAreSuspended {
                logger.info(
                    """
                    Selected display sleep prevention while its effect is \
                    suspended for closed-lid mode
                    """
                )
            } else {
                logger.info("Enabled display sleep prevention")
            }
            return
        }

        guard displayOnIsEnabled || displayAssertion != nil else {
            return
        }

        try deactivateDisplayOnEffect()
        displayOnIsEnabled = false
        logger.info("Disabled display sleep prevention")
    }

    private func activateDisplayOnEffect() throws {
        guard displayOnIsEnabled, displayAssertion == nil else {
            return
        }

        displayAssertion = try createNamedAssertion(
            kind: .preventUserIdleDisplaySleep,
            reason: Self.displayReason,
            operationName: "display"
        )
    }

    private func deactivateDisplayOnEffect() throws {
        guard let identifier = displayAssertion else {
            return
        }

        try releaseAssertion(identifier, operationName: "display")
        displayAssertion = nil
    }

    private func createNamedAssertion(
        kind: PowerAssertionKind,
        reason: String,
        operationName: String
    ) throws -> IOPMAssertionID {
        do {
            return try powerAssertionBackend.createAssertion(
                kind: kind,
                reason: reason,
                operationName: operationName
            )
        } catch {
            logger.error(
                "Could not create the \(operationName, privacy: .public) assertion: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func releaseAssertion(
        _ identifier: IOPMAssertionID,
        operationName: String
    ) throws {
        do {
            try powerAssertionBackend.releaseAssertion(
                identifier,
                operationName: operationName
            )
        } catch {
            logger.error(
                "Could not release the \(operationName, privacy: .public) assertion: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func setScreenSaverPrevention(
        _ enabled: Bool
    ) throws {
        if enabled {
            guard !screenSaverPreventionIsEnabled else {
                return
            }

            screenSaverPreventionIsEnabled = true
            do {
                if !lidDisplayPolicy.state
                    .caffeineDisplayEffectsAreSuspended {
                    try activateScreenSaverEffect()
                }
            } catch {
                screenSaverPreventionIsEnabled = false
                throw error
            }
            if lidDisplayPolicy.state
                .caffeineDisplayEffectsAreSuspended {
                logger.info(
                    """
                    Selected screen saver prevention while its effect is \
                    suspended for closed-lid mode
                    """
                )
            } else {
                logger.info("Enabled screen saver prevention")
            }
            return
        }

        guard screenSaverPreventionIsEnabled
                || activityAssertion != nil
                || screenSaverTask != nil else {
            return
        }

        // Keep the pulse loop alive until the assertion is actually released.
        // If release fails, the controller will leave the menu checked and the
        // recurring effect must remain truthful and retryable.
        try deactivateScreenSaverEffect()
        screenSaverPreventionIsEnabled = false
        logger.info("Disabled screen saver prevention")
    }

    private func activateScreenSaverEffect() throws {
        guard screenSaverPreventionIsEnabled else {
            return
        }

        try declareUserActivity()
        startScreenSaverPulseLoop()
    }

    private func deactivateScreenSaverEffect() throws {
        try releaseActivityAssertion()
        screenSaverTask?.cancel()
        screenSaverTask = nil
    }

    private func declareUserActivity() throws {
        do {
            activityAssertion =
                try powerAssertionBackend
                    .declareUserActivity(
                        reason: Self.screenSaverReason,
                        existingIdentifier:
                            activityAssertion
                    )
        } catch {
            logger.error(
                "Could not declare user activity: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func releaseActivityAssertion() throws {
        guard let identifier = activityAssertion else {
            return
        }

        try releaseAssertion(identifier, operationName: "user activity")
        activityAssertion = nil
    }

    private func startScreenSaverPulseLoop() {
        screenSaverTask?.cancel()
        let pulseNanoseconds =
            timing.screenSaverPulseNanoseconds
        screenSaverTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: pulseNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                await self.pulseScreenSaverPrevention()
            }
        }
    }

    private func pulseScreenSaverPrevention() async {
        guard screenSaverPreventionIsEnabled,
              !lidDisplayPolicy.state
                .caffeineDisplayEffectsAreSuspended else {
            return
        }

        do {
            try declareUserActivity()
        } catch {
            logger.error(
                "Screen saver prevention was lost: \(String(describing: error), privacy: .public)"
            )
            screenSaverPreventionIsEnabled = false
            screenSaverTask?.cancel()
            screenSaverTask = nil
            try? releaseActivityAssertion()
            await effectLostHandler?(.screenSaver, .activationFailed)
        }
    }

    private func updateLidDisplayPolicy(
        lidModeEnabled: Bool,
        environment: LidDisplayEnvironmentState,
        allowDisplaySleepRequest: Bool = true
    ) throws {
        let actions = lidDisplayPolicy.update(
            lidModeEnabled: lidModeEnabled,
            lidClosed: environment.clamshellState == .closed,
            hasExternalDisplay:
                environment.hasOnlineExternalDisplay
        )
        try executeLidDisplayPolicyActions(
            actions,
            allowDisplaySleepRequest:
                allowDisplaySleepRequest
        )
    }

    private func executeLidDisplayPolicyActions(
        _ actions: [LidDisplayPolicyAction],
        allowDisplaySleepRequest: Bool = true
    ) throws {
        for action in actions {
            if case let .cancelDisplayIdleRequest(generation) =
                action {
                cancelDisplaySleepRequest(generation: generation)
                continue
            }

            guard lidDisplayPolicy.shouldExecute(action) else {
                continue
            }

            switch action {
            case .suspendCaffeineDisplayEffects:
                try suspendCaffeineDisplayEffectsForLid()

            case .restoreCaffeineDisplayEffects:
                try restoreCaffeineDisplayEffectsAfterLid()

            case let .requestDisplayIdle(generation):
                if allowDisplaySleepRequest {
                    startDisplaySleepRequest(
                        generation: generation
                    )
                } else {
                    // During an unconfirmed helper cleanup, Caffeine only
                    // retains the display-effect suppression needed for
                    // safety. The user's lid option is off, so it must not
                    // initiate a new global display-sleep command.
                    _ = lidDisplayPolicy.finishDisplayIdleRequest(
                        generation: generation
                    )
                }

            case .cancelDisplayIdleRequest:
                break
            }
        }
    }

    private func suspendCaffeineDisplayEffectsForLid() throws {
        var firstError: (any Error)?

        do {
            try deactivateDisplayOnEffect()
        } catch {
            firstError = error
        }

        do {
            try deactivateScreenSaverEffect()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }

        logger.info(
            """
            Suspended Caffeine-owned display effects while the closed Mac has \
            no external display
            """
        )
    }

    private func restoreCaffeineDisplayEffectsAfterLid() throws {
        var firstError: (any Error)?

        do {
            try activateDisplayOnEffect()
        } catch {
            firstError = error
        }

        do {
            try activateScreenSaverEffect()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }

        logger.info(
            "Restored Caffeine-owned display effects after headless lid mode"
        )
    }

    private func startDisplaySleepRequest(
        generation: LidDisplayPolicyGeneration
    ) {
        let action = LidDisplayPolicyAction.requestDisplayIdle(
            generation: generation
        )
        guard lidDisplayPolicy.shouldExecute(action),
              displaySleepTasks[generation] == nil,
              let sessionIdentifier = lidSessionIdentifier else {
            return
        }

        let requester = displaySleepRequester
        let debounceNanoseconds =
            timing.displaySleepDebounceNanoseconds
        displaySleepTasks[generation] = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds:
                        debounceNanoseconds
                )
                try Task.checkCancellation()
                guard let self,
                      await self.displaySleepRequestIsCurrent(
                        generation: generation
                      ) else {
                    return
                }

                await self.startDisplaySleepCommandTimeout(
                    generation: generation
                )
                let outcome =
                    try await requester.requestDisplaySleep()
                await self.displaySleepCommandDidReturn(
                    generation: generation
                )

                switch outcome {
                case let .exited(result):
                    guard result.succeeded else {
                        await self.displaySleepRequestFinished(
                            generation: generation,
                            completion: .result(result)
                        )
                        return
                    }

                    do {
                        try await self
                            .verifyBuiltInDisplayWentToSleep(
                                generation: generation
                            )
                        await self.displaySleepRequestFinished(
                            generation: generation,
                            completion: .result(result)
                        )
                    } catch is CancellationError {
                        await self
                            .registerLateDisplaySleepWakeIfNeeded(
                                sessionIdentifier:
                                    sessionIdentifier,
                                generation: generation
                            )
                    } catch {
                        await self.displaySleepRequestFinished(
                            generation: generation,
                            completion: .failure(
                                String(describing: error)
                            )
                        )
                    }

                case .cancelledAfterLaunch:
                    await self
                        .registerLateDisplaySleepWakeIfNeeded(
                            sessionIdentifier:
                                sessionIdentifier,
                            generation: generation
                        )
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.displaySleepRequestFinished(
                    generation: generation,
                    completion: .failure(
                        String(describing: error)
                    )
                )
            }
        }
    }

    private func displaySleepCommandDidReturn(
        generation: LidDisplayPolicyGeneration
    ) {
        displaySleepTimeoutTasks
            .removeValue(forKey: generation)?
            .cancel()
    }

    private func verifyBuiltInDisplayWentToSleep(
        generation: LidDisplayPolicyGeneration
    ) async throws {
        let timeoutNanoseconds =
            timing.displaySleepVerificationTimeoutNanoseconds
        let pollNanoseconds = max(
            timing.displaySleepVerificationPollNanoseconds,
            1
        )
        var elapsedNanoseconds: UInt64 = 0
        var lastReadError: (any Error)?

        while true {
            try Task.checkCancellation()
            guard displaySleepRequestIsCurrent(
                generation: generation
            ) else {
                throw CancellationError()
            }

            do {
                if try builtInDisplaySleepReader
                    .builtInDisplayIsAsleep() {
                    return
                }
                lastReadError = nil
            } catch {
                // Display topology can be briefly unreadable while the panel
                // transitions. Retry inside the same bounded verification
                // window, then fail safe if a valid sleeping state never
                // arrives.
                lastReadError = error
            }

            guard elapsedNanoseconds < timeoutNanoseconds else {
                break
            }
            let remainingNanoseconds =
                timeoutNanoseconds - elapsedNanoseconds
            let delayNanoseconds = min(
                pollNanoseconds,
                remainingNanoseconds
            )
            guard delayNanoseconds > 0 else {
                break
            }
            try await Task.sleep(
                nanoseconds: delayNanoseconds
            )
            elapsedNanoseconds += delayNanoseconds
        }

        let detail: String
        if let lastReadError {
            detail =
                "the display state remained unreadable (\(lastReadError))."
        } else {
            detail =
                "the panel remained awake through the verification window."
        }
        throw PowerControlError.displaySleepNotConfirmed(detail)
    }

    private func registerLateDisplaySleepWakeIfNeeded(
        sessionIdentifier: UUID,
        generation: LidDisplayPolicyGeneration
    ) {
        guard lidIsEnabled,
              lidSessionIdentifier == sessionIdentifier,
              lidDisplayPolicy.state.generation == generation,
              !lidDisplayPolicy.state.isEffectivelyHeadless else {
            return
        }

        pendingLateDisplayWake = (
            sessionIdentifier: sessionIdentifier,
            generation: generation
        )
        if lidEnvironmentIsValid,
           let environment = lidEnvironmentState {
            reconcilePendingLateDisplayWake(
                for: environment
            )
        }
    }

    private func reconcilePendingLateDisplayWake(
        for environment: LidDisplayEnvironmentState
    ) {
        guard let pendingLateDisplayWake else {
            return
        }
        guard lidIsEnabled,
              lidSessionIdentifier
                == pendingLateDisplayWake.sessionIdentifier,
              lidDisplayPolicy.state.generation
                == pendingLateDisplayWake.generation else {
            self.pendingLateDisplayWake = nil
            return
        }
        guard lidEnvironmentIsValid else {
            return
        }

        // A completed non-external topology makes the late global request
        // harmless for clamshell use. Consume the token so repeated snapshots
        // cannot trigger a later unrelated wake.
        self.pendingLateDisplayWake = nil
        guard environment.hasOnlineExternalDisplay,
              !lidDisplayPolicy.state.isEffectivelyHeadless else {
            return
        }

        do {
            let identifier =
                try powerAssertionBackend.declareUserActivity(
                    reason: Self.lateDisplayWakeReason,
                    existingIdentifier: nil
                )
            do {
                try powerAssertionBackend.releaseAssertion(
                    identifier,
                    operationName:
                        "late display-sleep reconciliation"
                )
            } catch {
                logger.error(
                    """
                    Could not release the late display wake assertion: \
                    \(String(describing: error), privacy: .public)
                    """
                )
            }
            logger.notice(
                """
                Reconciled a canceled display-sleep request after an external \
                display appeared
                """
            )
        } catch {
            logger.error(
                """
                Could not wake an external display after canceling display \
                sleep: \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private func displaySleepRequestIsCurrent(
        generation: LidDisplayPolicyGeneration
    ) -> Bool {
        lidDisplayPolicy.shouldExecute(
            .requestDisplayIdle(generation: generation)
        )
    }

    private func cancelDisplaySleepRequest(
        generation: LidDisplayPolicyGeneration
    ) {
        displaySleepTasks.removeValue(forKey: generation)?.cancel()
        displaySleepTimeoutTasks
            .removeValue(forKey: generation)?
            .cancel()
    }

    private func cancelAllDisplaySleepRequests() {
        let tasks = displaySleepTasks.values
        displaySleepTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        let timeoutTasks = displaySleepTimeoutTasks.values
        displaySleepTimeoutTasks.removeAll()
        for task in timeoutTasks {
            task.cancel()
        }
    }

    private func startDisplaySleepCommandTimeout(
        generation: LidDisplayPolicyGeneration
    ) {
        guard displaySleepTasks[generation] != nil,
              displaySleepTimeoutTasks[generation] == nil else {
            return
        }

        let timeoutNanoseconds =
            timing.displaySleepTimeoutNanoseconds
        displaySleepTimeoutTasks[generation] = Task {
            [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds:
                        timeoutNanoseconds
                )
            } catch {
                return
            }
            await self?.displaySleepCommandTimedOut(
                generation: generation
            )
        }
    }

    private func displaySleepCommandTimedOut(
        generation: LidDisplayPolicyGeneration
    ) async {
        displaySleepTimeoutTasks.removeValue(
            forKey: generation
        )
        guard let requestTask = displaySleepTasks.removeValue(
            forKey: generation
        ) else {
            return
        }
        requestTask.cancel()

        guard lidDisplayPolicy.finishDisplayIdleRequest(
            generation: generation
        ) else {
            return
        }
        await handleCurrentLidDisplayPolicyFailure(
            operation: .requestDisplayIdle,
            generation: generation,
            description:
                "The display-sleep command did not finish within 2 seconds."
        )
    }

    private func displaySleepRequestFinished(
        generation: LidDisplayPolicyGeneration,
        completion: DisplaySleepCompletion
    ) async {
        displaySleepTasks.removeValue(forKey: generation)
        displaySleepTimeoutTasks
            .removeValue(forKey: generation)?
            .cancel()

        guard lidDisplayPolicy.finishDisplayIdleRequest(
            generation: generation
        ) else {
            return
        }

        switch completion {
        case let .failure(description):
            await handleCurrentLidDisplayPolicyFailure(
                operation: .requestDisplayIdle,
                generation: generation,
                description: description
            )
            return

        case let .result(commandResult):
            guard !commandResult.succeeded else {
                logger.info(
                    """
                    Requested immediate display sleep for lid generation \
                    \(generation.rawValue, privacy: .public)
                    """
                )
                return
            }
            let error = PowerControlError.displaySleepCommandFailed(
                status: commandResult.terminationStatus,
                standardError: commandResult.standardError
            )
            await handleCurrentLidDisplayPolicyFailure(
                operation: .requestDisplayIdle,
                generation: generation,
                description:
                    error.localizedDescription
            )
            return
        }
    }

    private func handleCurrentLidDisplayPolicyFailure(
        operation: LidDisplayPolicyOperation,
        generation: LidDisplayPolicyGeneration?,
        description: String,
        notifyEffectLoss: Bool = true
    ) async {
        guard lidIsEnabled, !lidPolicyFailureInProgress else {
            return
        }
        if let generation {
            guard lidDisplayPolicy.state.generation == generation else {
                return
            }
        }
        guard let sessionIdentifier = lidSessionIdentifier else {
            return
        }

        lidPolicyFailureInProgress = true
        logger.error(
            "Withdrawing lid-closed mode after \(String(describing: operation), privacy: .public) failed: \(description, privacy: .public)"
        )

        lidIsEnabled = false
        cancelAllDisplaySleepRequests()

        let connection = lidConnection
        let connectionIdentifier = lidConnectionIdentifier
        var helperWasCleared = connection == nil

        if let connection {
            do {
                try await sendSleepDisabled(false, over: connection)
                helperWasCleared = true
            } catch {
                logger.error(
                    """
                    Display-policy fail-safe could not confirm helper cleanup: \
                    \(String(describing: error), privacy: .public)
                    """
                )
            }
        }

        let stillOwnsSession =
            lidSessionIdentifier == sessionIdentifier
            && lidConnectionIdentifier == connectionIdentifier
        if stillOwnsSession {
            lidConnection = nil
            lidConnectionIdentifier = nil
            lidSessionIdentifier = nil
        }
        connection?.invalidate()

        if stillOwnsSession {
            if helperWasCleared {
                let didRestore =
                    await stopLidDisplayPolicyAndRestoreEffects(
                    expectedSessionIdentifier:
                        sessionIdentifier
                )
                if didRestore {
                    lidCleanupAwaitingHelperClear = false
                    lidCleanupSessionIdentifier = nil
                }
            } else {
                beginDeferredLidCleanupDisplaySafety(
                    sessionIdentifier: sessionIdentifier
                )
                startLidRecovery(
                    cleanupSessionIdentifier:
                        sessionIdentifier
                )
            }
        } else if helperWasCleared,
                  lidCleanupSessionIdentifier
                    == sessionIdentifier {
            // The connection invalidation callback may have moved this exact
            // session into recovery while the successful clear reply was
            // crossing. A confirmed false value safely ends that hold.
            cancelLidRecovery()
            await finishDeferredLidCleanupAfterConfirmedClear(
                sessionIdentifier: sessionIdentifier
            )
        }

        if notifyEffectLoss {
            await effectLostHandler?(
                .lidClosed,
                .displaySleepFailed
            )
        }
        lidPolicyFailureInProgress = false
    }

    private func reportUnrestoredSelectedDisplayEffects() async {
        if displayOnIsEnabled, displayAssertion == nil {
            displayOnIsEnabled = false
            await effectLostHandler?(.displayOn, .activationFailed)
        }
        if screenSaverPreventionIsEnabled,
           activityAssertion == nil {
            screenSaverPreventionIsEnabled = false
            screenSaverTask?.cancel()
            screenSaverTask = nil
            await effectLostHandler?(
                .screenSaver,
                .activationFailed
            )
        }
    }

    private func startLidDisplayObservation(
        sessionIdentifier: UUID
    )
        async throws -> LidDisplayEnvironmentState
    {
        let identifier = sessionIdentifier
        lidObservationIdentifier = identifier
        lidEnvironmentState = nil
        lidEnvironmentIsValid = false
        lidObservationFailureDescription = nil

        var eventContinuation:
            AsyncStream<LidDisplayEnvironmentEvent>
                .Continuation?
        let eventStream = AsyncStream<
            LidDisplayEnvironmentEvent
        > { continuation in
            eventContinuation = continuation
        }
        guard let eventContinuation else {
            lidObservationIdentifier = nil
            throw PowerControlError.operationSuperseded
        }
        lidObservationEventContinuation = eventContinuation
        lidObservationEventTask = Task { [weak self] in
            for await event in eventStream {
                guard !Task.isCancelled else {
                    return
                }
                await self?.lidDisplayEnvironmentEventReceived(
                    event,
                    observationIdentifier: identifier
                )
            }
        }

        do {
            try lidDisplayEnvironmentObserver.start { event in
                eventContinuation.yield(event)
            }
        } catch {
            stopLidDisplayObservation(
                expectedSessionIdentifier: identifier
            )
            throw error
        }

        do {
            return try await waitForInitialLidEnvironment(
                observationIdentifier: identifier
            )
        } catch {
            if lidObservationIdentifier == identifier {
                stopLidDisplayObservation(
                    expectedSessionIdentifier: identifier
                )
            }
            throw error
        }
    }

    private func waitForInitialLidEnvironment(
        observationIdentifier: UUID
    ) async throws -> LidDisplayEnvironmentState {
        try await withCheckedThrowingContinuation {
            continuation in
            guard lidObservationIdentifier
                    == observationIdentifier else {
                continuation.resume(
                    throwing: PowerControlError.operationSuperseded
                )
                return
            }

            initialLidEnvironmentWaiter = (
                identifier: observationIdentifier,
                continuation: continuation
            )
            initialLidEnvironmentTimeoutTask?.cancel()
            let timeoutNanoseconds =
                timing.lidEnvironmentTimeoutNanoseconds
            initialLidEnvironmentTimeoutTask = Task {
                [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds:
                            timeoutNanoseconds
                    )
                } catch {
                    return
                }
                await self?.initialLidEnvironmentTimedOut(
                    observationIdentifier: observationIdentifier
                )
            }
        }
    }

    private func initialLidEnvironmentTimedOut(
        observationIdentifier: UUID
    ) {
        guard initialLidEnvironmentWaiter?.identifier
                == observationIdentifier else {
            return
        }
        resumeInitialLidEnvironmentWaiter(
            with: .failure(
                PowerControlError.lidDisplayObservationTimedOut
            )
        )
    }

    private func resumeInitialLidEnvironmentWaiter(
        with result: Result<LidDisplayEnvironmentState, Error>
    ) {
        let waiter = initialLidEnvironmentWaiter
        initialLidEnvironmentWaiter = nil
        initialLidEnvironmentTimeoutTask?.cancel()
        initialLidEnvironmentTimeoutTask = nil
        waiter?.continuation.resume(with: result)
    }

    private func lidDisplayEnvironmentEventReceived(
        _ event: LidDisplayEnvironmentEvent,
        observationIdentifier: UUID
    ) async {
        guard lidObservationIdentifier
                == observationIdentifier else {
            return
        }

        switch event {
        case let .state(environment):
            displayConfigurationTimeoutTask?.cancel()
            displayConfigurationTimeoutTask = nil
            lidEnvironmentState = environment
            lidEnvironmentIsValid = true
            lidObservationFailureDescription = nil
            if initialLidEnvironmentWaiter?.identifier
                == observationIdentifier {
                resumeInitialLidEnvironmentWaiter(
                    with: .success(environment)
                )
            }

            if lidCleanupAwaitingHelperClear {
                pendingLateDisplayWake = nil
                do {
                    try reconcileDeferredLidCleanupDisplaySafety(
                        environment: environment
                    )
                } catch {
                    logger.error(
                        """
                        Could not reconcile display safety while helper \
                        cleanup is pending: \
                        \(String(describing: error), privacy: .public)
                        """
                    )
                }
                return
            }

            guard lidIsEnabled else {
                return
            }
            do {
                try updateLidDisplayPolicy(
                    lidModeEnabled: true,
                    environment: environment
                )
            } catch {
                await handleCurrentLidDisplayPolicyFailure(
                    operation:
                        .suspendCaffeineDisplayEffects,
                    generation:
                        lidDisplayPolicy.state.generation,
                    description: String(describing: error)
                )
            }
            reconcilePendingLateDisplayWake(
                for: environment
            )

        case .displayConfigurationBegan:
            // Until CoreGraphics commits and re-enumerates the new topology,
            // conservatively assume an external display exists. This cancels
            // delayed global sleep before a newly attached monitor can be
            // blanked, without withdrawing otherwise healthy lid mode.
            lidEnvironmentIsValid = false
            startDisplayConfigurationTimeout(
                observationIdentifier: observationIdentifier
            )
            guard let environment = lidEnvironmentState else {
                return
            }

            if lidCleanupAwaitingHelperClear {
                // A topology transition is not evidence that an external
                // display is usable. Keep a closed Mac suppressed until the
                // completed snapshot proves a safe topology.
                retainDeferredCleanupSafetyForUnknownTopology(
                    context: "during topology reconfiguration"
                )
                return
            }

            guard lidIsEnabled else {
                return
            }
            let conservativeEnvironment = LidDisplayEnvironmentState(
                clamshellState: environment.clamshellState,
                hasOnlineExternalDisplay: true
            )
            lidEnvironmentState = conservativeEnvironment
            do {
                try updateLidDisplayPolicy(
                    lidModeEnabled: true,
                    environment: conservativeEnvironment
                )
            } catch {
                await handleCurrentLidDisplayPolicyFailure(
                    operation:
                        .restoreCaffeineDisplayEffects,
                    generation:
                        lidDisplayPolicy.state.generation,
                    description: String(describing: error)
                )
            }

        case let .observationFailed(failure):
            pendingLateDisplayWake = nil
            displayConfigurationTimeoutTask?.cancel()
            displayConfigurationTimeoutTask = nil
            lidEnvironmentIsValid = false
            lidObservationFailureDescription =
                failure.localizedDescription
            if initialLidEnvironmentWaiter?.identifier
                == observationIdentifier {
                resumeInitialLidEnvironmentWaiter(
                    with: .failure(failure)
                )
            }

            if lidCleanupAwaitingHelperClear {
                retainDeferredCleanupSafetyForUnknownTopology(
                    context: "after topology observation failed"
                )
                return
            }

            guard lidIsEnabled else {
                return
            }
            await handleCurrentLidDisplayPolicyFailure(
                operation: .requestDisplayIdle,
                generation: nil,
                description: failure.localizedDescription
            )
        }
    }

    private func startDisplayConfigurationTimeout(
        observationIdentifier: UUID
    ) {
        displayConfigurationTimeoutTask?.cancel()
        let timeoutNanoseconds =
            timing.displayConfigurationTimeoutNanoseconds
        displayConfigurationTimeoutTask = Task {
            [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds:
                        timeoutNanoseconds
                )
            } catch {
                return
            }
            await self?.displayConfigurationTimedOut(
                observationIdentifier: observationIdentifier
            )
        }
    }

    private func displayConfigurationTimedOut(
        observationIdentifier: UUID
    ) async {
        displayConfigurationTimeoutTask = nil
        guard lidObservationIdentifier
                == observationIdentifier,
              !lidEnvironmentIsValid else {
            return
        }

        let description =
            "Display reconfiguration did not finish within 2 seconds."
        lidObservationFailureDescription = description
        if initialLidEnvironmentWaiter?.identifier
            == observationIdentifier {
            resumeInitialLidEnvironmentWaiter(
                with: .failure(
                    PowerControlError
                        .lidDisplayObservationFailed(
                            description
                        )
                )
            )
        }

        if lidCleanupAwaitingHelperClear {
            retainDeferredCleanupSafetyForUnknownTopology(
                context:
                    "after topology reconfiguration timed out"
            )
            return
        }

        guard lidIsEnabled else {
            return
        }
        await handleCurrentLidDisplayPolicyFailure(
            operation: .requestDisplayIdle,
            generation: nil,
            description: description
        )
    }

    @discardableResult
    private func stopLidDisplayObservation(
        expectedSessionIdentifier: UUID? = nil
    ) -> Bool {
        if let expectedSessionIdentifier,
           lidObservationIdentifier
            != expectedSessionIdentifier {
            return false
        }

        lidObservationIdentifier = nil
        pendingLateDisplayWake = nil
        lidDisplayEnvironmentObserver.stop()
        lidObservationEventContinuation?.finish()
        lidObservationEventContinuation = nil
        lidObservationEventTask?.cancel()
        lidObservationEventTask = nil
        displayConfigurationTimeoutTask?.cancel()
        displayConfigurationTimeoutTask = nil
        lidEnvironmentIsValid = false
        lidObservationFailureDescription = nil
        if initialLidEnvironmentWaiter != nil {
            resumeInitialLidEnvironmentWaiter(
                with: .failure(
                    PowerControlError.operationSuperseded
                )
            )
        } else {
            initialLidEnvironmentTimeoutTask?.cancel()
            initialLidEnvironmentTimeoutTask = nil
        }
        return true
    }

    private func setLidSleepDisabled(
        _ disabled: Bool
    ) async throws {
        if disabled {
            guard !lidIsEnabled else {
                return
            }
            guard !lidCleanupAwaitingHelperClear else {
                // A previous helper lease is not yet known to be clear.
                // Starting a new session would make stale recovery and XPC
                // completions ambiguous, so require the bounded repair loop
                // to establish a safe baseline first.
                throw PowerControlError.helperUnavailable
            }
            guard lidConnection == nil else {
                throw PowerControlError.operationSuperseded
            }

            cancelLidRecovery()
            let sessionIdentifier = UUID()
            lidSessionIdentifier = sessionIdentifier

            let initialEnvironment: LidDisplayEnvironmentState
            do {
                initialEnvironment =
                    try await startLidDisplayObservation(
                        sessionIdentifier:
                            sessionIdentifier
                    )
            } catch {
                if lidSessionIdentifier == sessionIdentifier {
                    lidSessionIdentifier = nil
                }
                logger.error(
                    """
                    Could not start lid/display observation before enabling \
                    closed-lid mode: \
                    \(String(describing: error), privacy: .public)
                    """
                )
                throw error
            }

            guard lidSessionIdentifier == sessionIdentifier,
                  lidObservationIdentifier
                    == sessionIdentifier else {
                throw PowerControlError.operationSuperseded
            }

            let connectionIdentifier = UUID()
            let connection = makeHelperConnection(
                identifier: connectionIdentifier,
                sessionIdentifier: sessionIdentifier
            )
            lidConnection = connection
            lidConnectionIdentifier = connectionIdentifier

            do {
                try await sendSleepDisabled(
                    true,
                    over: connection
                )
            } catch {
                let stillOwnsSession =
                    lidSessionIdentifier == sessionIdentifier
                    && lidConnectionIdentifier
                        == connectionIdentifier
                if stillOwnsSession {
                    lidConnection = nil
                    lidConnectionIdentifier = nil
                    lidSessionIdentifier = nil
                    lidIsEnabled = false
                }
                connection.invalidate()
                if stillOwnsSession {
                    beginDeferredLidCleanupDisplaySafety(
                        sessionIdentifier: sessionIdentifier
                    )
                    startLidRecovery(
                        cleanupSessionIdentifier:
                            sessionIdentifier
                    )
                }
                logger.error(
                    "Could not enable lid-closed sleep prevention: \(String(describing: error), privacy: .public)"
                )
                throw error
            }

            guard lidSessionIdentifier == sessionIdentifier,
                  lidConnectionIdentifier
                    == connectionIdentifier else {
                // The connection was intentionally torn down while the request
                // was in flight. Its invalidation removes the helper lease.
                connection.invalidate()
                stopLidDisplayObservation(
                    expectedSessionIdentifier:
                        sessionIdentifier
                )
                throw PowerControlError.operationSuperseded
            }

            lidIsEnabled = true

            if let observationFailure =
                lidObservationFailureDescription {
                let error =
                    PowerControlError
                        .lidDisplayObservationFailed(
                            observationFailure
                        )
                await handleCurrentLidDisplayPolicyFailure(
                    operation: .requestDisplayIdle,
                    generation: nil,
                    description: error.localizedDescription,
                    notifyEffectLoss: false
                )
                throw error
            }

            guard lidEnvironmentIsValid else {
                let error =
                    PowerControlError
                        .lidDisplayObservationFailed(
                            """
                            Display topology changed before activation \
                            completed.
                            """
                        )
                await handleCurrentLidDisplayPolicyFailure(
                    operation: .requestDisplayIdle,
                    generation: nil,
                    description: error.localizedDescription,
                    notifyEffectLoss: false
                )
                throw error
            }

            let environment =
                lidEnvironmentState ?? initialEnvironment
            do {
                try updateLidDisplayPolicy(
                    lidModeEnabled: true,
                    environment: environment
                )
            } catch {
                await handleCurrentLidDisplayPolicyFailure(
                    operation:
                        .suspendCaffeineDisplayEffects,
                    generation:
                        lidDisplayPolicy.state.generation,
                    description: String(describing: error),
                    notifyEffectLoss: false
                )
                throw error
            }

            logger.info("Enabled lid-closed sleep prevention")
            return
        }

        guard let connection = lidConnection else {
            lidIsEnabled = false
            // A failed helper clear deliberately leaves the effects and
            // observer under the recovery hold. "Off" in the menu is not proof
            // that restoring the panel-affecting effects is safe.
            if !lidCleanupAwaitingHelperClear,
               let sessionIdentifier = lidSessionIdentifier {
                lidSessionIdentifier = nil
                _ = await stopLidDisplayPolicyAndRestoreEffects(
                    expectedSessionIdentifier:
                        sessionIdentifier
                )
            }
            return
        }

        let connectionIdentifier = lidConnectionIdentifier
        guard let sessionIdentifier = lidSessionIdentifier else {
            connection.invalidate()
            throw PowerControlError.operationSuperseded
        }

        do {
            try await sendSleepDisabled(false, over: connection)

            // Clear local ownership only after the helper has confirmed the
            // persistent setting is off. Until then, retaining the connection
            // keeps the helper lease and the checked menu state truthful.
            guard lidSessionIdentifier == sessionIdentifier,
                  lidConnectionIdentifier
                    == connectionIdentifier else {
                connection.invalidate()
                return
            }

            lidConnection = nil
            lidConnectionIdentifier = nil
            lidSessionIdentifier = nil
            lidIsEnabled = false
            lidCleanupAwaitingHelperClear = false
            lidCleanupSessionIdentifier = nil
            _ = await stopLidDisplayPolicyAndRestoreEffects(
                expectedSessionIdentifier:
                    sessionIdentifier
            )
            connection.invalidate()
            logger.info("Disabled lid-closed sleep prevention")
        } catch {
            logger.error(
                "Could not disable lid-closed sleep prevention: \(String(describing: error), privacy: .public)"
            )

            // The result is either known to have failed or unknowable. Fail
            // closed in the UI, invalidate the lease, and start an independent
            // repair connection instead of retaining a checked option whose
            // persistent effect cannot be proved.
            guard lidSessionIdentifier == sessionIdentifier,
                  lidConnectionIdentifier
                    == connectionIdentifier else {
                connection.invalidate()
                throw PowerControlError.operationSuperseded
            }
            abandonLidConnectionAfterDisableFailure(
                connection,
                identifier: connectionIdentifier,
                sessionIdentifier: sessionIdentifier
            )
            throw PowerEffectStateError.noLongerControlled
        }
    }

    private func stopLidDisplayPolicyAndRestoreEffects(
        expectedSessionIdentifier: UUID? = nil
    ) async -> Bool {
        guard stopLidDisplayObservation(
            expectedSessionIdentifier:
                expectedSessionIdentifier
        ) else {
            return false
        }
        cancelAllDisplaySleepRequests()

        let currentInput = lidDisplayPolicy.state.input
        let restoreActions = lidDisplayPolicy.update(
            lidModeEnabled: false,
            lidClosed: currentInput.lidClosed,
            hasExternalDisplay:
                currentInput.hasExternalDisplay
        )
        do {
            try executeLidDisplayPolicyActions(restoreActions)
        } catch {
            logger.error(
                """
                Could not fully restore selected display effects while \
                stopping lid mode: \
                \(String(describing: error), privacy: .public)
                """
            )
        }
        lidEnvironmentState = nil
        await reportUnrestoredSelectedDisplayEffects()
        return true
    }

    private func beginDeferredLidCleanupDisplaySafety(
        sessionIdentifier: UUID
    ) {
        lidCleanupAwaitingHelperClear = true
        lidCleanupSessionIdentifier = sessionIdentifier
        cancelAllDisplaySleepRequests()

        let environment: LidDisplayEnvironmentState
        if !lidEnvironmentIsValid
            || lidObservationFailureDescription != nil {
            // With an unconfirmed helper clear, an incomplete/failed joined
            // topology cannot borrow the last known open-lid state. Treat all
            // unknown topology as closed and headless until a fresh joined
            // state proves otherwise.
            environment =
                Self.conservativeUnknownLidEnvironment
            lidEnvironmentState = environment
        } else if let observedEnvironment = lidEnvironmentState {
            environment = observedEnvironment
        } else {
            environment =
                Self.conservativeUnknownLidEnvironment
            lidEnvironmentState = environment
        }
        do {
            try reconcileDeferredLidCleanupDisplaySafety(
                environment: environment
            )
        } catch {
            logger.error(
                """
                Could not establish the display-safety hold while helper \
                cleanup is pending: \
                \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private func finishDeferredLidCleanupAfterConfirmedClear(
        sessionIdentifier: UUID
    ) async {
        guard lidCleanupAwaitingHelperClear,
              lidCleanupSessionIdentifier
                == sessionIdentifier else {
            return
        }

        let didRestore =
            await stopLidDisplayPolicyAndRestoreEffects(
            expectedSessionIdentifier: sessionIdentifier
        )
        if didRestore {
            lidCleanupAwaitingHelperClear = false
            lidCleanupSessionIdentifier = nil
        }
    }

    /// Reconciles display effects while the lid option is logically off but a
    /// failed/lost helper connection has not yet proved `SleepDisabled=false`.
    ///
    /// A lid-open or external-display state is safe for normal display effects.
    /// A closed Mac with no confirmed external display stays suppressed. This
    /// path deliberately consumes, rather than executes, any new global
    /// display-sleep request because the user-facing lid option is already off.
    private func reconcileDeferredLidCleanupDisplaySafety(
        environment: LidDisplayEnvironmentState
    ) throws {
        guard lidCleanupAwaitingHelperClear else {
            return
        }

        try updateLidDisplayPolicy(
            lidModeEnabled: true,
            environment: environment,
            allowDisplaySleepRequest: false
        )
    }

    private func retainDeferredCleanupSafetyForUnknownTopology(
        context: String
    ) {
        guard lidEnvironmentState != nil else {
            return
        }

        let environment =
            Self.conservativeUnknownLidEnvironment
        lidEnvironmentState = environment
        do {
            try reconcileDeferredLidCleanupDisplaySafety(
                environment: environment
            )
        } catch {
            logger.error(
                """
                Could not retain display safety \(context, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private func abandonLidConnectionAfterDisableFailure(
        _ connection: any LidHelperLeaseClient,
        identifier: UUID?,
        sessionIdentifier: UUID
    ) {
        guard lidConnectionIdentifier == identifier,
              lidSessionIdentifier == sessionIdentifier else {
            connection.invalidate()
            return
        }

        lidConnection = nil
        lidConnectionIdentifier = nil
        lidSessionIdentifier = nil
        lidIsEnabled = false
        connection.invalidate()

        beginDeferredLidCleanupDisplaySafety(
            sessionIdentifier: sessionIdentifier
        )
        startLidRecovery(
            cleanupSessionIdentifier: sessionIdentifier
        )
    }

    private func makeHelperConnection(
        identifier: UUID,
        sessionIdentifier: UUID
    ) -> any LidHelperLeaseClient {
        lidHelperClientFactory.makeClient { [weak self] in
            Task {
                await self?.helperConnectionWasLost(
                    identifier,
                    sessionIdentifier: sessionIdentifier
                )
            }
        }
    }

    private func helperConnectionWasLost(
        _ identifier: UUID,
        sessionIdentifier: UUID
    ) async {
        guard lidConnectionIdentifier == identifier,
              lidSessionIdentifier == sessionIdentifier else {
            return
        }

        let hadActiveEffect = lidIsEnabled
        lidConnection = nil
        lidConnectionIdentifier = nil
        lidSessionIdentifier = nil
        lidIsEnabled = false
        beginDeferredLidCleanupDisplaySafety(
            sessionIdentifier: sessionIdentifier
        )

        if hadActiveEffect {
            logger.error(
                "The helper connection ended while lid-closed prevention was active"
            )
            await effectLostHandler?(
                .lidClosed,
                .helperConnectionLost
            )
        }
        startLidRecovery(
            cleanupSessionIdentifier: sessionIdentifier
        )
    }

    /// Reconnects only to force the persistent setting off after an unexpected
    /// helper loss. Asking launchd for the Mach service also relaunches a
    /// crashed, still-approved daemon so its startup clear can run.
    private func startLidRecovery(
        cleanupSessionIdentifier: UUID? = nil
    ) {
        if let cleanupSessionIdentifier,
           lidCleanupSessionIdentifier == nil {
            lidCleanupSessionIdentifier =
                cleanupSessionIdentifier
        }
        if lidRecoveryTask != nil {
            if let cleanupSessionIdentifier {
                lidRecoveryCleanupSessionIdentifier =
                    cleanupSessionIdentifier
            }
            return
        }

        let recoveryIdentifier = UUID()
        let initialDelayNanoseconds =
            timing.recoveryInitialDelayNanoseconds
        let maximumDelayNanoseconds =
            timing.recoveryMaximumDelayNanoseconds
        lidRecoveryIdentifier = recoveryIdentifier
        lidRecoveryCleanupSessionIdentifier =
            cleanupSessionIdentifier
        lidRecoveryTask = Task { [weak self] in
            var retryDelayNanoseconds =
                initialDelayNanoseconds

            while !Task.isCancelled {
                guard let self else {
                    return
                }

                if await self.attemptLidRecovery() {
                    await self.finishLidRecovery(
                        identifier: recoveryIdentifier
                    )
                    return
                }

                do {
                    try await Task.sleep(
                        nanoseconds: retryDelayNanoseconds
                    )
                } catch {
                    return
                }
                retryDelayNanoseconds = min(
                    retryDelayNanoseconds * 2,
                    maximumDelayNanoseconds
                )
            }
        }
    }

    private func cancelLidRecovery() {
        lidRecoveryTask?.cancel()
        lidRecoveryTask = nil
        lidRecoveryIdentifier = nil
        lidRecoveryCleanupSessionIdentifier = nil
    }

    private func attemptLidRecovery() async -> Bool {
        let connection =
            lidHelperClientFactory.makeClient(
                lossHandler: {}
            )

        defer {
            connection.invalidate()
        }

        do {
            try await sendSleepDisabled(false, over: connection)
            logger.notice(
                "Recovered the persistent lid-closed sleep setting after helper loss"
            )
            return true
        } catch {
            logger.error(
                "Lid-closed sleep recovery will retry: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    private func finishLidRecovery(identifier: UUID) async {
        guard lidRecoveryIdentifier == identifier else {
            return
        }
        let cleanupSessionIdentifier =
            lidRecoveryCleanupSessionIdentifier
        lidRecoveryTask = nil
        lidRecoveryIdentifier = nil
        lidRecoveryCleanupSessionIdentifier = nil

        if let cleanupSessionIdentifier,
           lidCleanupSessionIdentifier
            == cleanupSessionIdentifier {
            await finishDeferredLidCleanupAfterConfirmedClear(
                sessionIdentifier:
                    cleanupSessionIdentifier
            )
        }
    }

    private func sendSleepDisabled(
        _ disabled: Bool,
        over connection: any LidHelperLeaseClient
    ) async throws {
        try await connection.setSleepDisabled(
            disabled,
            timeoutNanoseconds:
                timing.helperReplyTimeoutNanoseconds
        )
    }
}
