import CaffeineIPC
import Foundation
import IOKit.pwr_mgt
import OSLog

struct SystemPowerControllerTiming: Equatable, Sendable {
    var helperReplyTimeoutNanoseconds: UInt64
    var lidEnvironmentTimeoutNanoseconds: UInt64
    var displaySleepDebounceNanoseconds: UInt64
    var displaySleepTimeoutNanoseconds: UInt64
    var displaySleepVerificationTimeoutNanoseconds: UInt64
    var displaySleepVerificationPollNanoseconds: UInt64
    var displayConfigurationTimeoutNanoseconds: UInt64
    var screenSaverPulseNanoseconds: UInt64
    var recoveryInitialDelayNanoseconds: UInt64
    var recoveryMaximumDelayNanoseconds: UInt64

    static let production = SystemPowerControllerTiming(
        helperReplyTimeoutNanoseconds: 2_000_000_000,
        lidEnvironmentTimeoutNanoseconds: 2_000_000_000,
        displaySleepDebounceNanoseconds: 300_000_000,
        displaySleepTimeoutNanoseconds: 2_000_000_000,
        displaySleepVerificationTimeoutNanoseconds: 2_000_000_000,
        displaySleepVerificationPollNanoseconds: 100_000_000,
        displayConfigurationTimeoutNanoseconds: 2_000_000_000,
        screenSaverPulseNanoseconds: 30_000_000_000,
        recoveryInitialDelayNanoseconds: 500_000_000,
        recoveryMaximumDelayNanoseconds: 60_000_000_000
    )
}

protocol LidHelperLeaseClient: AnyObject, Sendable {
    func setSleepDisabled(
        _ disabled: Bool,
        timeoutNanoseconds: UInt64
    ) async throws

    func invalidate()
}

protocol LidHelperLeaseClientFactory: Sendable {
    func makeClient(
        lossHandler: @escaping @Sendable () -> Void
    ) -> any LidHelperLeaseClient
}

struct XPCLidHelperLeaseClientFactory:
    LidHelperLeaseClientFactory,
    Sendable
{
    let logger: Logger

    func makeClient(
        lossHandler: @escaping @Sendable () -> Void
    ) -> any LidHelperLeaseClient {
        XPCLidHelperLeaseClient(
            logger: logger,
            lossHandler: lossHandler
        )
    }
}

private final class XPCLidHelperLeaseClient:
    LidHelperLeaseClient,
    @unchecked Sendable
{
    private let connection: NSXPCConnection
    private let logger: Logger

    init(
        logger: Logger,
        lossHandler: @escaping @Sendable () -> Void
    ) {
        self.logger = logger

        let connection = NSXPCConnection(
            machServiceName: CaffeineIPC.helperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: CaffeineHelperProtocol.self
        )
        connection.setCodeSigningRequirement(
            Self.helperCodeSigningRequirement(logger: logger)
        )
        connection.interruptionHandler = lossHandler
        connection.invalidationHandler = lossHandler
        self.connection = connection
        connection.activate()
    }

    func setSleepDisabled(
        _ disabled: Bool,
        timeoutNanoseconds: UInt64
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = LidHelperReplyGate(
                continuation: continuation
            )

            let proxy = connection.remoteObjectProxyWithErrorHandler {
                [logger] error in
                gate.resume(
                    with: .failure(
                        PowerControlError.helperUnavailable
                    )
                )
                logger.error(
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
                            PowerControlError
                                .helperRejectedRequest
                        )
                )
            }

            Task {
                try? await Task.sleep(
                    nanoseconds: timeoutNanoseconds
                )
                gate.resume(
                    with: .failure(
                        PowerControlError.helperTimedOut
                    )
                )
            }
        }
    }

    func invalidate() {
        connection.invalidate()
    }

    private static func helperCodeSigningRequirement(
        logger: Logger
    ) -> String {
        if let requirement =
            CodeSigningRequirementReader
                .embeddedHelperRequirement(),
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
}

private final class LidHelperReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        let continuationToResume: CheckedContinuation<Void, Error>? =
            lock.withLock {
                defer {
                    continuation = nil
                }
                return continuation
            }
        continuationToResume?.resume(with: result)
    }
}

enum PowerAssertionKind: Equatable, Sendable {
    case preventUserIdleSystemSleep
    case preventUserIdleDisplaySleep
}

protocol PowerAssertionBackend: Sendable {
    func createAssertion(
        kind: PowerAssertionKind,
        reason: String,
        operationName: String
    ) throws -> IOPMAssertionID

    func releaseAssertion(
        _ identifier: IOPMAssertionID,
        operationName: String
    ) throws

    func declareUserActivity(
        reason: String,
        existingIdentifier: IOPMAssertionID?
    ) throws -> IOPMAssertionID
}

struct IOKitPowerAssertionBackend:
    PowerAssertionBackend,
    Sendable
{
    func createAssertion(
        kind: PowerAssertionKind,
        reason: String,
        operationName: String
    ) throws -> IOPMAssertionID {
        let assertionType: CFString
        switch kind {
        case .preventUserIdleSystemSleep:
            assertionType =
                kIOPMAssertionTypePreventUserIdleSystemSleep
                    as CFString
        case .preventUserIdleDisplaySleep:
            assertionType =
                kIOPMAssertionTypePreventUserIdleDisplaySleep
                    as CFString
        }

        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &identifier
        )
        guard result == kIOReturnSuccess else {
            throw PowerControlError.ioKit(
                operation: "Creating the \(operationName) assertion",
                result: result
            )
        }
        return identifier
    }

    func releaseAssertion(
        _ identifier: IOPMAssertionID,
        operationName: String
    ) throws {
        let result = IOPMAssertionRelease(identifier)
        guard result == kIOReturnSuccess
                || result == kIOReturnNotFound else {
            throw PowerControlError.ioKit(
                operation: "Releasing the \(operationName) assertion",
                result: result
            )
        }
    }

    func declareUserActivity(
        reason: String,
        existingIdentifier: IOPMAssertionID?
    ) throws -> IOPMAssertionID {
        var identifier = existingIdentifier ?? 0
        let result = IOPMAssertionDeclareUserActivity(
            reason as CFString,
            kIOPMUserActiveLocal,
            &identifier
        )
        guard result == kIOReturnSuccess else {
            throw PowerControlError.ioKit(
                operation: "Declaring user activity",
                result: result
            )
        }
        return identifier
    }
}
