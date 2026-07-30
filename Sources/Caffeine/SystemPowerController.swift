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
        case .operationSuperseded:
            return "The power operation was superseded."
        }
    }
}

actor SystemPowerController: PowerControlling {
    typealias EffectLostHandler =
        @MainActor @Sendable (WakeOption) -> Void

    private static let displayReason =
        "Caffeine is keeping the display awake"
    private static let screenSaverReason =
        "Caffeine is preventing the screen saver"
    private static let helperTimeoutNanoseconds: UInt64 = 2_000_000_000

    private let logger: Logger

    private var displayAssertion: IOPMAssertionID?
    private var activityAssertion: IOPMAssertionID?
    private var screenSaverIsEnabled = false
    private var screenSaverTask: Task<Void, Never>?

    private var lidConnection: NSXPCConnection?
    private var lidConnectionIdentifier: UUID?
    private var lidIsEnabled = false
    private var lidRecoveryTask: Task<Void, Never>?
    private var lidRecoveryIdentifier: UUID?

    private var effectLostHandler: EffectLostHandler?

    init(
        logger: Logger = Logger(
            subsystem: CaffeineIPC.applicationIdentifier,
            category: "Power"
        )
    ) {
        self.logger = logger
    }

    func setEffectLostHandler(
        _ handler: EffectLostHandler?
    ) {
        effectLostHandler = handler
    }

    func setEnabled(
        _ enabled: Bool,
        for option: WakeOption
    ) async throws {
        switch option {
        case .displayOn:
            try setDisplayOn(enabled)
        case .screenSaver:
            try setScreenSaverPrevention(enabled)
        case .lidClosed:
            try await setLidSleepDisabled(enabled)
        }
    }

    private func setDisplayOn(_ enabled: Bool) throws {
        if enabled {
            guard displayAssertion == nil else {
                return
            }

            var identifier: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.displayReason as CFString,
                &identifier
            )
            guard result == kIOReturnSuccess else {
                logger.error(
                    "Could not create the display assertion: IOKit result 0x\(String(result, radix: 16), privacy: .public)"
                )
                throw PowerControlError.ioKit(
                    operation: "Creating the display assertion",
                    result: result
                )
            }
            displayAssertion = identifier
            logger.info("Enabled display sleep prevention")
            return
        }

        guard let identifier = displayAssertion else {
            return
        }

        let result = IOPMAssertionRelease(identifier)
        guard result == kIOReturnSuccess || result == kIOReturnNotFound else {
            logger.error(
                "Could not release the display assertion: IOKit result 0x\(String(result, radix: 16), privacy: .public)"
            )
            throw PowerControlError.ioKit(
                operation: "Releasing the display assertion",
                result: result
            )
        }
        displayAssertion = nil
        logger.info("Disabled display sleep prevention")
    }

    private func setScreenSaverPrevention(
        _ enabled: Bool
    ) throws {
        if enabled {
            guard !screenSaverIsEnabled else {
                return
            }

            try declareUserActivity()
            screenSaverIsEnabled = true
            startScreenSaverPulseLoop()
            logger.info("Enabled screen saver prevention")
            return
        }

        guard screenSaverIsEnabled || activityAssertion != nil else {
            return
        }

        // Keep the pulse loop alive until the assertion is actually released.
        // If release fails, the controller will leave the menu checked and the
        // recurring effect must remain truthful and retryable.
        try releaseActivityAssertion()
        screenSaverIsEnabled = false
        screenSaverTask?.cancel()
        screenSaverTask = nil
        logger.info("Disabled screen saver prevention")
    }

    private func declareUserActivity() throws {
        var identifier = activityAssertion ?? 0
        let result = IOPMAssertionDeclareUserActivity(
            Self.screenSaverReason as CFString,
            kIOPMUserActiveLocal,
            &identifier
        )
        guard result == kIOReturnSuccess else {
            logger.error(
                "Could not declare user activity: IOKit result 0x\(String(result, radix: 16), privacy: .public)"
            )
            throw PowerControlError.ioKit(
                operation: "Declaring user activity",
                result: result
            )
        }
        activityAssertion = identifier
    }

    private func releaseActivityAssertion() throws {
        guard let identifier = activityAssertion else {
            return
        }

        let result = IOPMAssertionRelease(identifier)
        guard result == kIOReturnSuccess || result == kIOReturnNotFound else {
            logger.error(
                "Could not release the user activity assertion: IOKit result 0x\(String(result, radix: 16), privacy: .public)"
            )
            throw PowerControlError.ioKit(
                operation: "Releasing the user activity assertion",
                result: result
            )
        }
        activityAssertion = nil
    }

    private func startScreenSaverPulseLoop() {
        screenSaverTask?.cancel()
        screenSaverTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
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
        guard screenSaverIsEnabled else {
            return
        }

        do {
            try declareUserActivity()
        } catch {
            logger.error(
                "Screen saver prevention was lost: \(String(describing: error), privacy: .public)"
            )
            screenSaverIsEnabled = false
            screenSaverTask?.cancel()
            screenSaverTask = nil
            try? releaseActivityAssertion()
            await effectLostHandler?(.screenSaver)
        }
    }

    private func setLidSleepDisabled(
        _ disabled: Bool
    ) async throws {
        if disabled {
            guard !lidIsEnabled else {
                return
            }

            cancelLidRecovery()

            let connectionIdentifier = UUID()
            let connection = makeHelperConnection(
                identifier: connectionIdentifier
            )
            lidConnection = connection
            lidConnectionIdentifier = connectionIdentifier
            connection.activate()

            do {
                try await sendSleepDisabled(
                    true,
                    over: connection
                )
            } catch {
                if lidConnectionIdentifier == connectionIdentifier {
                    lidConnection = nil
                    lidConnectionIdentifier = nil
                    lidIsEnabled = false
                }
                connection.invalidate()
                startLidRecovery()
                logger.error(
                    "Could not enable lid-closed sleep prevention: \(String(describing: error), privacy: .public)"
                )
                throw error
            }

            guard lidConnectionIdentifier == connectionIdentifier else {
                // The connection was intentionally torn down while the request
                // was in flight. Its invalidation removes the helper lease.
                connection.invalidate()
                throw PowerControlError.operationSuperseded
            }

            lidIsEnabled = true
            logger.info("Enabled lid-closed sleep prevention")
            return
        }

        guard let connection = lidConnection else {
            lidIsEnabled = false
            return
        }

        let connectionIdentifier = lidConnectionIdentifier

        do {
            try await sendSleepDisabled(false, over: connection)

            // Clear local ownership only after the helper has confirmed the
            // persistent setting is off. Until then, retaining the connection
            // keeps the helper lease and the checked menu state truthful.
            guard lidConnectionIdentifier == connectionIdentifier else {
                connection.invalidate()
                return
            }

            lidConnection = nil
            lidConnectionIdentifier = nil
            lidIsEnabled = false
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
            abandonLidConnectionAfterDisableFailure(
                connection,
                identifier: connectionIdentifier
            )
            throw PowerEffectStateError.noLongerControlled
        }
    }

    private func abandonLidConnectionAfterDisableFailure(
        _ connection: NSXPCConnection,
        identifier: UUID?
    ) {
        guard lidConnectionIdentifier == identifier else {
            connection.invalidate()
            return
        }

        lidConnection = nil
        lidConnectionIdentifier = nil
        lidIsEnabled = false
        connection.invalidate()

        startLidRecovery()
    }

    private func makeHelperConnection(
        identifier: UUID
    ) -> NSXPCConnection {
        let connection = makeConfiguredHelperConnection()
        connection.interruptionHandler = { [weak self] in
            Task {
                await self?.helperConnectionWasLost(identifier)
            }
        }
        connection.invalidationHandler = { [weak self] in
            Task {
                await self?.helperConnectionWasLost(identifier)
            }
        }
        return connection
    }

    private func helperConnectionWasLost(_ identifier: UUID) async {
        guard lidConnectionIdentifier == identifier else {
            return
        }

        let hadActiveEffect = lidIsEnabled
        lidConnection = nil
        lidConnectionIdentifier = nil
        lidIsEnabled = false

        if hadActiveEffect {
            logger.error(
                "The helper connection ended while lid-closed prevention was active"
            )
            await effectLostHandler?(.lidClosed)
        }
        startLidRecovery()
    }

    /// Reconnects only to force the persistent setting off after an unexpected
    /// helper loss. Asking launchd for the Mach service also relaunches a
    /// crashed, still-approved daemon so its startup clear can run.
    private func startLidRecovery() {
        guard lidRecoveryTask == nil else {
            return
        }

        let recoveryIdentifier = UUID()
        lidRecoveryIdentifier = recoveryIdentifier
        lidRecoveryTask = Task { [weak self] in
            var retryDelayNanoseconds: UInt64 = 500_000_000

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
                    60_000_000_000
                )
            }
        }
    }

    private func cancelLidRecovery() {
        lidRecoveryTask?.cancel()
        lidRecoveryTask = nil
        lidRecoveryIdentifier = nil
    }

    private func attemptLidRecovery() async -> Bool {
        let connection = makeConfiguredHelperConnection()
        connection.activate()

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

    private func finishLidRecovery(identifier: UUID) {
        guard lidRecoveryIdentifier == identifier else {
            return
        }
        lidRecoveryTask = nil
        lidRecoveryIdentifier = nil
    }

    private func makeConfiguredHelperConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: CaffeineIPC.helperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: CaffeineHelperProtocol.self
        )
        connection.setCodeSigningRequirement(
            helperCodeSigningRequirement()
        )
        return connection
    }

    private func helperCodeSigningRequirement() -> String {
        if let requirement =
            CodeSigningRequirementReader.embeddedHelperRequirement(),
            !requirement.isEmpty {
            return requirement
        }

        logger.fault(
            "The embedded helper has no designated code requirement"
        )
        // Fail closed without crashing unrelated keep-awake features. No real
        // helper can satisfy this placeholder requirement.
        return #"cdhash H"0000000000000000000000000000000000000000""#
    }

    private func sendSleepDisabled(
        _ disabled: Bool,
        over connection: NSXPCConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = XPCReplyGate(continuation: continuation)

            let proxy = connection.remoteObjectProxyWithErrorHandler {
                error in
                gate.resume(
                    with: .failure(
                        PowerControlError.helperUnavailable
                    )
                )
                self.logger.error(
                    "Helper XPC error: \(String(describing: error), privacy: .public)"
                )
            }

            guard let helper = proxy as? CaffeineHelperProtocol else {
                gate.resume(
                    with: .failure(
                        PowerControlError.helperUnavailable
                    )
                )
                return
            }

            helper.setSleepDisabled(disabled) { success in
                gate.resume(
                    with: success
                        ? .success(())
                        : .failure(
                            PowerControlError.helperRejectedRequest
                        )
                )
            }

            Task {
                try? await Task.sleep(
                    nanoseconds: Self.helperTimeoutNanoseconds
                )
                gate.resume(
                    with: .failure(PowerControlError.helperTimedOut)
                )
            }
        }
    }
}

private final class XPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        let continuationToResume: CheckedContinuation<Void, Error>? =
            lock.withLock {
                defer { continuation = nil }
                return continuation
            }
        continuationToResume?.resume(with: result)
    }
}
