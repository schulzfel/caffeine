import Foundation

/// Owns Caffeine's durable selection state and coordinates all platform side
/// effects. AppKit should render `state.menuPresentation` and forward menu
/// actions to this type.
@MainActor
public final class CaffeineController {
    private static let restoredLidRetryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(750),
        .seconds(2),
    ]

    public private(set) var state: CaffeineState

    /// Called synchronously on the main actor whenever observable state changes.
    public var onStateChange: ((CaffeineState) -> Void)?

    /// One-shot UI work that does not belong in the platform-neutral state.
    public var onEvent: ((CaffeineControllerEvent) -> Void)?

    private let powerController: any PowerControlling
    private let helperRegistration: any HelperRegistrationManaging
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private let preferencesStore: any PreferencesStoring
    private let sleepBeforeLidRestoreRetry: (Duration) async -> Void

    private var storedPreferences = StoredPreferences()
    private var optionRevisions: [WakeOption: UInt64] = Dictionary(
        uniqueKeysWithValues: WakeOption.allCases.map { ($0, 0) }
    )
    private var launchAtLoginRevision: UInt64 = 0
    private var lidRestoreRetryInProgress = false
    private var hasStarted = false

    public init(
        powerController: any PowerControlling,
        helperRegistration: any HelperRegistrationManaging,
        launchAtLoginManager: any LaunchAtLoginManaging,
        preferencesStore: any PreferencesStoring,
        sleepBeforeLidRestoreRetry: @escaping (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        }
    ) {
        self.powerController = powerController
        self.helperRegistration = helperRegistration
        self.launchAtLoginManager = launchAtLoginManager
        self.preferencesStore = preferencesStore
        self.sleepBeforeLidRestoreRetry = sleepBeforeLidRestoreRetry
        state = CaffeineState()
    }

    /// Loads, normalizes, and reapplies the user's durable selections.
    ///
    /// Calling this more than once is a no-op.
    public func start() async {
        guard !hasStarted, state.lifecycle != .quitting else {
            return
        }
        hasStarted = true

        let loadedPreferences = preferencesStore.load()
        storedPreferences = loadedPreferences.normalized()
        if storedPreferences != loadedPreferences {
            preferencesStore.save(storedPreferences)
        }

        hydrateStateFromPreferences()
        publish()

        let helperStatus = await helperRegistration.status()
        guard state.lifecycle != .quitting else {
            return
        }
        state.helperStatus = helperStatus
        publish()

        let loginStatus = await launchAtLoginManager.status()
        guard state.lifecycle != .quitting else {
            return
        }
        state.launchAtLogin = ExternalToggleState(status: loginStatus)
        publish()

        for option in [WakeOption.displayOn, .screenSaver] {
            guard state.lifecycle != .quitting else {
                return
            }
            if state[option].intent == .enabled {
                await enableStandardOption(option)
            }
        }

        guard state.lifecycle != .quitting else {
            return
        }
        if state[.lidClosed].intent != .off {
            await enableLidOption(userInitiated: false)
        }

        guard state.lifecycle != .quitting else {
            return
        }
        state.lifecycle = .running
        publish()

        await retryRestoredLidOptionIfNeeded()
    }

    /// Toggles one independent keep-awake option.
    public func toggle(_ option: WakeOption) async {
        guard canAcceptUserAction,
              !state.bulkOperationInProgress,
              !state[option].effect.isTransitioning else {
            return
        }

        if state[option].intent == .waitingForApproval {
            await enableLidOption(userInitiated: true)
            return
        }

        if state[option].effect.isEffectivelyActive {
            await disableOption(option)
        } else {
            await enableOption(option, userInitiated: true)
        }
    }

    /// Implements the menu's Enable All / Disable All action.
    ///
    /// Enabling is deliberately not transactional: options that succeed remain
    /// enabled if another option fails or has to wait for helper approval.
    public func toggleAll() async {
        guard canAcceptUserAction,
              !state.bulkOperationInProgress,
              !state.hasTransitioningWakeOption else {
            return
        }

        let shouldDisable = state.hasActiveWakeOption
        state.bulkOperationInProgress = true
        publish()

        if shouldDisable {
            if state[.lidClosed].intent == .waitingForApproval {
                // Supersede any approval refresh before replacing the pending
                // request with the user's global off target.
                _ = nextRevision(for: .lidClosed)
            }
            commitBulkTarget(.off)

            // Clear the global lid setting first, and never short-circuit after
            // an individual failure.
            for option in [WakeOption.lidClosed, .screenSaver, .displayOn] {
                guard state.lifecycle != .quitting else {
                    return
                }
                if state[option].effect.isEffectivelyActive {
                    await disableOption(option)
                }
            }
        } else {
            commitBulkTarget(.enabled)

            for option in WakeOption.allCases {
                guard state.lifecycle != .quitting else {
                    return
                }
                if !state[option].effect.isEffectivelyActive {
                    await enableOption(option, userInitiated: true)
                }
            }
        }

        guard state.lifecycle != .quitting else {
            return
        }
        state.bulkOperationInProgress = false
        publish()
    }

    /// Reconciles settings that can be changed outside the running app.
    ///
    /// AppKit should call this from `menuWillOpen`.
    public func refreshExternalState() async {
        guard canAcceptUserAction else {
            return
        }

        await refreshLaunchAtLoginStatus()
        await refreshLidHelperStatus()
        await retryRestoredLidOptionIfNeeded()
    }

    private func refreshLidHelperStatus() async {
        guard canAcceptUserAction,
              !state[.lidClosed].effect.isTransitioning else {
            return
        }

        let revision = currentRevision(for: .lidClosed)
        let observedStatus = await helperRegistration.status()
        guard canAcceptUserAction,
              isCurrent(revision, for: .lidClosed) else {
            return
        }

        state.helperStatus = observedStatus
        publish()

        let lidState = state[.lidClosed]
        switch (lidState.intent, observedStatus) {
        case (.enabled, .enabled)
            where lidState.effect == .inactive:
            // A persisted lid request may have been restored before launchd
            // finished bringing up the helper. Retry quietly once the helper
            // reports ready instead of requiring another user click.
            await enableLidOption(
                userInitiated: false,
                knownReadiness: .ready
            )

        case (.waitingForApproval, .enabled):
            await enableLidOption(
                userInitiated: false,
                knownReadiness: .ready
            )

        case (.waitingForApproval, .notRegistered):
            await enableLidOption(userInitiated: false)

        case (.waitingForApproval, .requiresApproval):
            break

        case (.waitingForApproval, .notFound):
            failLidOption(with: .helperNotFound)

        case (.waitingForApproval, .unknown):
            // The helper may be crossing from approval into its running state.
            // Keep the pending request durable while the bounded retry below
            // waits for a definitive Service Management observation.
            break

        case (.off, .requiresApproval)
            where lidState.issue == .helperConnectionLost:
            // An XPC loss can arrive just before the status observation that
            // explains it. Preserve the user's prior request as a quiet pending
            // approval instead of requiring an unrelated second click.
            moveLidOptionToWaiting(userInitiated: false)

        case (.enabled, .requiresApproval):
            if lidState.effect.isEffectivelyActive {
                await clearActiveLidEffect(
                    observedRevision: revision,
                    destination: .waitingForApproval
                )
            } else {
                moveLidOptionToWaiting(userInitiated: false)
            }

        case (.enabled, .notRegistered):
            if lidState.effect.isEffectivelyActive {
                await clearActiveLidEffect(
                    observedRevision: revision,
                    destination: .off(issue: .helperUnavailable)
                )
            } else {
                await enableLidOption(userInitiated: false)
            }

        case (.enabled, .notFound):
            if lidState.effect.isEffectivelyActive {
                await clearActiveLidEffect(
                    observedRevision: revision,
                    destination: .off(issue: .helperNotFound)
                )
            } else {
                await enableLidOption(userInitiated: false)
            }

        case (.enabled, .unknown):
            // `.unknown` is a transient launchd-health observation. The live
            // XPC connection reports a real effect loss separately, so never
            // erase durable intent solely because this probe raced startup.
            break

        default:
            break
        }
    }

    private func retryRestoredLidOptionIfNeeded() async {
        guard !lidRestoreRetryInProgress,
              shouldRetryRestoredLidOption else {
            return
        }

        lidRestoreRetryInProgress = true
        defer {
            lidRestoreRetryInProgress = false
        }

        for delay in Self.restoredLidRetryDelays {
            guard shouldRetryRestoredLidOption else {
                return
            }

            await sleepBeforeLidRestoreRetry(delay)

            guard shouldRetryRestoredLidOption else {
                return
            }
            await refreshLidHelperStatus()
        }
    }

    private var shouldRetryRestoredLidOption: Bool {
        guard state.lifecycle == .running,
              state[.lidClosed].effect == .inactive else {
            return false
        }

        switch state[.lidClosed].intent {
        case .enabled:
            return state[.lidClosed].issue == .helperUnavailable
        case .waitingForApproval:
            return state.helperStatus == .unknown
        case .off:
            return false
        }
    }

    /// Keeps a lid request durable while the app hands off to the optional
    /// helper installer.
    ///
    /// This deliberately applies only to the stable, actionable state emitted
    /// after a user has requested lid-closed mode and helper installation was
    /// found to be necessary. The next app launch can then reconcile the
    /// request just like a pending helper approval.
    public func deferLidRequestForHelperInstallation() {
        guard state.lifecycle != .quitting,
              state[.lidClosed] == WakeOptionState(
                  intent: .off,
                  effect: .inactive,
                  issue: .helperRequiresInstallation
              ) else {
            return
        }

        _ = nextRevision(for: .lidClosed)
        moveLidOptionToWaiting(userInitiated: false)
    }

    public func toggleLaunchAtLogin() async {
        guard canAcceptUserAction,
              !state.launchAtLogin.isChanging else {
            return
        }

        if state.launchAtLogin.status == .requiresApproval {
            onEvent?(.requestLaunchAtLoginApproval)
            return
        }

        let shouldEnable: Bool
        switch state.launchAtLogin.status {
        case .enabled:
            shouldEnable = false
        case .notRegistered, .notFound, .unknown:
            shouldEnable = true
        case .requiresApproval:
            return
        }
        let revision = nextLaunchAtLoginRevision()
        state.launchAtLogin.isChanging = true
        state.launchAtLogin.issue = nil
        publish()

        var operationIssue: ExternalServiceIssue?
        do {
            if shouldEnable {
                try await launchAtLoginManager.register()
            } else {
                try await launchAtLoginManager.unregister()
            }
        } catch let error as ApplicationInstallationError {
            switch error {
            case .moveToApplications:
                operationIssue = .moveToApplications
            }
        } catch {
            // The status read below is authoritative. ServiceManagement can
            // report an error such as "already registered" even when the
            // requested state has already been reached.
            operationIssue = .changeFailed
        }

        let observedStatus = await launchAtLoginManager.status()
        guard canAcceptUserAction,
              revision == launchAtLoginRevision else {
            return
        }

        let reachedDesiredState: Bool
        if shouldEnable {
            reachedDesiredState = observedStatus == .enabled
                || observedStatus == .requiresApproval
        } else {
            reachedDesiredState = observedStatus == .notRegistered
                || observedStatus == .notFound
        }

        state.launchAtLogin = ExternalToggleState(
            status: observedStatus,
            isChanging: false,
            issue: reachedDesiredState
                ? nil
                : operationIssue ?? .changeFailed
        )
        publish()

        if shouldEnable, observedStatus == .requiresApproval {
            onEvent?(.requestLaunchAtLoginApproval)
        }
    }

    /// Reports that an effect disappeared outside a direct controller command
    /// (for example, a recurring activity pulse failed or an XPC connection
    /// was invalidated). A loss during activation also supersedes that
    /// activation so its eventual completion cannot commit a stale active
    /// state.
    ///
    /// This synchronously invalidates any stale operation for the option,
    /// rolls its durable selection back to off, and updates the menu.
    public func effectWasLost(
        _ option: WakeOption,
        issue: OptionIssue = .activationFailed
    ) {
        guard state.lifecycle != .quitting,
              state[option].effect != .inactive else {
            return
        }

        let lostState = state[option]
        _ = nextRevision(for: option)
        let resolvedIssue: OptionIssue
        if option == .lidClosed {
            // A connection that disappears while an explicit removal is in
            // progress must not recreate the request if approval is later
            // observed. Only an unsolicited active/applying loss retains that
            // provenance.
            resolvedIssue = lostState.effect == .removing
                ? .helperUnavailable
                : .helperConnectionLost
        } else {
            resolvedIssue = issue
        }
        state[option] = WakeOptionState(
            intent: .off,
            effect: .inactive,
            issue: resolvedIssue
        )
        persistStableState()
        publish()
    }

    /// Releases process effects while retaining all durable user selections.
    ///
    /// The AppKit termination path should await this method before exiting.
    public func shutdown() async {
        guard state.lifecycle != .quitting else {
            return
        }

        state.lifecycle = .quitting
        state.bulkOperationInProgress = false
        state.launchAtLogin.isChanging = false
        for option in WakeOption.allCases {
            _ = nextRevision(for: option)
        }
        _ = nextLaunchAtLoginRevision()
        publish()

        // Attempt every cleanup even if an earlier operation fails.
        for option in [WakeOption.lidClosed, .screenSaver, .displayOn] {
            do {
                try await powerController.setEnabled(false, for: option)
                state[option].effect = .inactive
            } catch {
                if state[option].effect.isEffectivelyActive {
                    state[option].issue = .deactivationFailed
                }
            }
            publish()
        }
    }

    // MARK: - Option operations

    private var canAcceptUserAction: Bool {
        state.lifecycle == .running
    }

    private func enableOption(
        _ option: WakeOption,
        userInitiated: Bool
    ) async {
        switch option {
        case .displayOn, .screenSaver:
            await enableStandardOption(option)
        case .lidClosed:
            await enableLidOption(userInitiated: userInitiated)
        }
    }

    private func enableStandardOption(_ option: WakeOption) async {
        let revision = nextRevision(for: option)
        state[option].intent = .enabled
        state[option].effect = .applying
        state[option].issue = nil
        persistStableState()
        publish()

        do {
            try await powerController.setEnabled(true, for: option)
        } catch {
            guard isCurrent(revision, for: option),
                  state.lifecycle != .quitting else {
                return
            }

            state[option] = WakeOptionState(
                intent: .off,
                effect: .inactive,
                issue: .activationFailed
            )
            persistStableState()
            publish()
            return
        }

        guard isCurrent(revision, for: option),
              state.lifecycle != .quitting else {
            // Shutdown may have issued its cleanup before this activation
            // completed, so compensate once more after the stale completion.
            // During normal operation, however, the revision may belong to a
            // newer retry; disabling here would tear down that newer effect.
            if state.lifecycle == .quitting {
                try? await powerController.setEnabled(false, for: option)
            }
            return
        }

        state[option] = WakeOptionState(
            intent: .enabled,
            effect: .active
        )
        persistStableState()
        publish()
    }

    private func enableLidOption(
        userInitiated: Bool,
        knownReadiness: ResolvedHelperReadiness? = nil
    ) async {
        let revision = nextRevision(for: .lidClosed)
        state[.lidClosed].intent = .enabled
        state[.lidClosed].effect = .applying
        state[.lidClosed].issue = nil
        persistStableState()
        publish()

        let readiness: ResolvedHelperReadiness
        if let knownReadiness {
            readiness = knownReadiness
        } else {
            readiness = await resolveHelperReadiness(revision: revision)
        }
        guard isCurrent(revision, for: .lidClosed),
              state.lifecycle != .quitting else {
            return
        }

        switch readiness {
        case .ready:
            break
        case .requiresApproval:
            moveLidOptionToWaiting(userInitiated: userInitiated)
            return
        case .unavailable(let issue):
            resolveLidEnableFailure(
                issue,
                userInitiated: userInitiated
            )
            if userInitiated,
               issue == .helperRequiresInstallation {
                onEvent?(.presentHelperInstallationRequired)
            }
            return
        }

        do {
            try await powerController.setEnabled(true, for: .lidClosed)
        } catch {
            guard isCurrent(revision, for: .lidClosed),
                  state.lifecycle != .quitting else {
                return
            }
            resolveLidEnableFailure(
                .helperUnavailable,
                userInitiated: userInitiated
            )
            return
        }

        guard isCurrent(revision, for: .lidClosed),
              state.lifecycle != .quitting else {
            if state.lifecycle == .quitting {
                try? await powerController.setEnabled(
                    false,
                    for: .lidClosed
                )
            }
            return
        }

        state[.lidClosed] = WakeOptionState(
            intent: .enabled,
            effect: .active
        )
        persistStableState()
        publish()
    }

    private enum ResolvedHelperReadiness {
        case ready
        case requiresApproval
        case unavailable(OptionIssue)
    }

    private enum LidStatusLossDestination {
        case waitingForApproval
        case off(issue: OptionIssue)
    }

    private func resolveHelperReadiness(
        revision: UInt64
    ) async -> ResolvedHelperReadiness {
        let initialStatus = await helperRegistration.status()
        guard isCurrent(revision, for: .lidClosed),
              state.lifecycle != .quitting else {
            return .unavailable(.helperUnavailable)
        }

        state.helperStatus = initialStatus
        publish()

        switch initialStatus {
        case .enabled:
            return .ready
        case .requiresApproval:
            return .requiresApproval
        case .unknown:
            return .unavailable(.helperUnavailable)
        case .notRegistered, .notFound:
            // Service Management can report `.notFound` when its registration
            // record is absent even though the embedded payload is readable.
            // Let the adapter attempt registration before diagnosing the
            // bundle as missing.
            break
        }

        let registrationResult = await helperRegistration.ensureRegistered()
        guard isCurrent(revision, for: .lidClosed),
              state.lifecycle != .quitting else {
            return .unavailable(.helperUnavailable)
        }

        let observedStatus = await helperRegistration.status()
        guard isCurrent(revision, for: .lidClosed),
              state.lifecycle != .quitting else {
            return .unavailable(.helperUnavailable)
        }

        state.helperStatus = observedStatus
        publish()

        // Status is authoritative where it gives a definitive answer. The
        // readiness result remains useful for adapters whose status update is
        // not immediately visible after registration.
        switch observedStatus {
        case .enabled:
            return .ready
        case .requiresApproval:
            return .requiresApproval
        case .unknown:
            return .unavailable(.helperUnavailable)
        case .notRegistered, .notFound:
            switch registrationResult {
            case .ready:
                state.helperStatus = .enabled
                publish()
                return .ready
            case .requiresApproval:
                state.helperStatus = .requiresApproval
                publish()
                return .requiresApproval
            case .moveToApplications:
                return .unavailable(.moveToApplications)
            case .requiresInstallation:
                return .unavailable(.helperRequiresInstallation)
            case .missing:
                return .unavailable(.helperNotFound)
            case .unavailable:
                return .unavailable(.helperUnavailable)
            }
        }
    }

    private func disableOption(_ option: WakeOption) async {
        let revision = nextRevision(for: option)
        state[option].intent = .off
        state[option].effect = .removing
        state[option].issue = nil
        persistStableState()
        publish()

        do {
            try await powerController.setEnabled(false, for: option)
        } catch {
            guard isCurrent(revision, for: option),
                  state.lifecycle != .quitting else {
                return
            }

            if let stateError = error as? PowerEffectStateError,
               stateError == .noLongerControlled {
                state[option] = WakeOptionState(
                    intent: .off,
                    effect: .inactive,
                    issue: option == .lidClosed
                        ? .helperUnavailable
                        : .deactivationFailed
                )
                persistStableState()
                publish()
                return
            }

            state[option].intent = .enabled
            state[option].effect = .active
            state[option].issue = .deactivationFailed
            persistStableState()
            publish()
            return
        }

        guard isCurrent(revision, for: option),
              state.lifecycle != .quitting else {
            return
        }

        state[option] = WakeOptionState()
        persistStableState()
        publish()
    }

    /// Reconciles an externally observed helper loss with the live XPC lease.
    ///
    /// ServiceManagement status alone does not prove that the helper process
    /// has ended or that its persistent system setting was cleared. Move
    /// through the normal removing state, explicitly relinquish the lease, and
    /// only then commit the status-derived destination if no newer operation
    /// superseded this reconciliation.
    private func clearActiveLidEffect(
        observedRevision: UInt64,
        destination: LidStatusLossDestination
    ) async {
        guard canAcceptUserAction,
              isCurrent(observedRevision, for: .lidClosed),
              state[.lidClosed].effect.isEffectivelyActive else {
            return
        }

        let cleanupRevision = nextRevision(for: .lidClosed)
        state[.lidClosed].effect = .removing
        state[.lidClosed].issue = nil
        publish()

        // The external status still determines the final UI state even if the
        // adapter reports an error. Its XPC invalidation path is a second
        // cleanup attempt, and retaining a known-stale active checkmark would
        // be more misleading than the quiet waiting/off destination.
        try? await powerController.setEnabled(false, for: .lidClosed)

        guard canAcceptUserAction else {
            return
        }

        if !isCurrent(cleanupRevision, for: .lidClosed) {
            // An XPC invalidation during this explicit cleanup reports one
            // effect loss and advances the revision once. Preserve the
            // already-observed ServiceManagement destination in that precise
            // race, while still refusing to overwrite any newer user action.
            let lossRevision = cleanupRevision &+ 1
            let lidState = state[.lidClosed]
            guard currentRevision(for: .lidClosed) == lossRevision,
                  lidState.intent == .off,
                  lidState.effect == .inactive,
                  lidState.issue == .helperUnavailable else {
                return
            }
        }

        switch destination {
        case .waitingForApproval:
            moveLidOptionToWaiting(userInitiated: false)
        case .off(let issue):
            failLidOption(with: issue)
        }
    }

    private func moveLidOptionToWaiting(userInitiated: Bool) {
        state[.lidClosed] = WakeOptionState(
            intent: .waitingForApproval,
            effect: .inactive
        )

        let shouldPresentExplanation = userInitiated
            && !storedPreferences.didExplainHelperApproval
        if shouldPresentExplanation {
            storedPreferences.didExplainHelperApproval = true
        }

        persistStableState()
        publish()

        if userInitiated {
            onEvent?(
                .requestHelperApproval(
                    showExplanation: shouldPresentExplanation
                )
            )
        }
    }

    private func failLidOption(with issue: OptionIssue) {
        state[.lidClosed] = WakeOptionState(
            intent: .off,
            effect: .inactive,
            issue: issue
        )
        persistStableState()
        publish()
    }

    private func resolveLidEnableFailure(
        _ issue: OptionIssue,
        userInitiated: Bool
    ) {
        guard !userInitiated, issue == .helperUnavailable else {
            failLidOption(with: issue)
            return
        }

        // During startup the helper's launchd job and XPC listener can lag the
        // app by a moment. Keep the durable request, show the inactive retry
        // hint, and let refreshExternalState reapply it when the helper is
        // observed as enabled.
        state[.lidClosed] = WakeOptionState(
            intent: .enabled,
            effect: .inactive,
            issue: .helperUnavailable
        )
        persistStableState()
        publish()
    }

    /// Records a bulk menu action's full durable target before its first
    /// platform await. Individual failures restore only the option that failed.
    private func commitBulkTarget(_ intent: OptionIntent) {
        for option in WakeOption.allCases {
            state[option].intent = intent
            state[option].issue = nil
        }
        persistStableState()
        publish()
    }

    // MARK: - External settings

    private func refreshLaunchAtLoginStatus() async {
        guard !state.launchAtLogin.isChanging else {
            return
        }

        let revision = nextLaunchAtLoginRevision()
        let observedStatus = await launchAtLoginManager.status()
        guard canAcceptUserAction,
              revision == launchAtLoginRevision else {
            return
        }

        state.launchAtLogin = ExternalToggleState(status: observedStatus)
        publish()
    }

    // MARK: - Persistence and observation

    private func hydrateStateFromPreferences() {
        var options = CaffeineState.emptyOptions
        for option in storedPreferences.enabledOptions {
            options[option] = WakeOptionState(intent: .enabled)
        }
        if storedPreferences.waitingForLidApproval {
            options[.lidClosed] = WakeOptionState(
                intent: .waitingForApproval
            )
        }

        state.options = options
        state.lifecycle = .starting
        state.bulkOperationInProgress = false
    }

    private func persistStableState() {
        storedPreferences.enabledOptions = Set(
            WakeOption.allCases.filter {
                state[$0].intent == .enabled
            }
        )
        storedPreferences.waitingForLidApproval =
            state[.lidClosed].intent == .waitingForApproval
        storedPreferences.normalize()
        preferencesStore.save(storedPreferences)
    }

    private func publish() {
        onStateChange?(state)
    }

    // MARK: - Revision tracking

    @discardableResult
    private func nextRevision(for option: WakeOption) -> UInt64 {
        let next = (optionRevisions[option] ?? 0) &+ 1
        optionRevisions[option] = next
        return next
    }

    private func currentRevision(for option: WakeOption) -> UInt64 {
        optionRevisions[option] ?? 0
    }

    private func isCurrent(_ revision: UInt64, for option: WakeOption) -> Bool {
        currentRevision(for: option) == revision
    }

    @discardableResult
    private func nextLaunchAtLoginRevision() -> UInt64 {
        launchAtLoginRevision &+= 1
        return launchAtLoginRevision
    }
}
