import CaffeineHelperCore
import CaffeineIPC
import CaffeineSPI
import Darwin
import Dispatch
import Foundation
import OSLog

private let helperLogger = Logger(
    subsystem: CaffeineIPC.helperIdentifier,
    category: "Helper"
)

private struct PowerSettingError: LocalizedError {
    let operation: String
    let result: CaffeineSPIResult

    var errorDescription: String? {
        switch result {
        case .unsupported:
            return "\(operation) SPI is unavailable on this macOS version"
        case .notPrivileged:
            return "the helper is not running with root privileges"
        default:
            return "IOKit could not \(operation) the SleepDisabled setting"
        }
    }
}

private struct OwnershipStoreError: LocalizedError {
    let operation: String
    let result: CaffeineSPIResult

    var errorDescription: String? {
        switch result {
        case .notPrivileged:
            return """
            \(operation) Caffeine's SleepDisabled ownership marker requires \
            root privileges
            """
        default:
            return """
            could not \(operation) Caffeine's durable SleepDisabled ownership \
            marker
            """
        }
    }
}

private func requireOwnershipStoreSuccess(
    _ result: CaffeineSPIResult,
    operation: String,
    cleanupOperation: String? = nil
) throws {
    guard result != .success else {
        return
    }

    let error = OwnershipStoreError(
        operation: operation,
        result: result
    )
    if result == .cleanupPending, let cleanupOperation {
        throw SleepDisabledCleanupPendingError(
            operation: cleanupOperation,
            cleanupError: error
        )
    }
    throw error
}

private struct CaffeineSPIOwnershipStore:
    SleepDisabledOwnershipStoring,
    Sendable
{
    func sleepDisabledOwnership() throws -> SleepDisabledOwnership? {
        var owned = false
        var priorDisabled = false
        let result = CaffeineSleepDisabledOwnershipStatus(
            &owned,
            &priorDisabled
        )
        try requireOwnershipStoreSuccess(
            result,
            operation: "read",
            cleanupOperation: "reading SleepDisabled ownership marker"
        )
        return owned
            ? SleepDisabledOwnership(priorDisabled: priorDisabled)
            : nil
    }

    func establishSleepDisabledOwnership(
        priorDisabled: Bool
    ) throws {
        let result = CaffeineEstablishSleepDisabledOwnership(
            priorDisabled
        )
        try requireOwnershipStoreSuccess(
            result,
            operation: "establish",
            cleanupOperation: "establishing SleepDisabled ownership marker"
        )
    }

    func relinquishSleepDisabledOwnership() throws {
        try requireOwnershipStoreSuccess(
            CaffeineRelinquishSleepDisabledOwnership(),
            operation: "remove"
        )
    }
}

private final class ConnectionService: NSObject, CaffeineHelperProtocol {
    private let coordinator: SleepDisabledLeaseCoordinator
    private let lease: SleepDisabledLease

    init(
        coordinator: SleepDisabledLeaseCoordinator,
        lease: SleepDisabledLease
    ) {
        self.coordinator = coordinator
        self.lease = lease
    }

    func setSleepDisabled(
        _ disabled: Bool,
        reply: @escaping (Bool) -> Void
    ) {
        reply(coordinator.setSleepDisabled(disabled, for: lease))
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let coordinator: SleepDisabledLeaseCoordinator

    init(coordinator: SleepDisabledLeaseCoordinator) {
        self.coordinator = coordinator
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let lease = coordinator.openConnection()
        let service = ConnectionService(
            coordinator: coordinator,
            lease: lease
        )

        connection.exportedInterface = NSXPCInterface(
            with: CaffeineHelperProtocol.self
        )
        connection.exportedObject = service
        connection.interruptionHandler = { [coordinator] in
            coordinator.invalidateConnection(lease)
        }
        connection.invalidationHandler = { [coordinator] in
            coordinator.invalidateConnection(lease)
        }
        connection.activate()
        return true
    }
}

private func applicationCodeSigningRequirement() -> String {
    let exactRequirement = ProcessInfo.processInfo.environment[
        "CAFFEINE_APP_REQUIREMENT"
    ]?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let exactRequirement,
       CaffeineIPC.exactCDHashes(in: exactRequirement) != nil {
        helperLogger.notice(
            "Using the installer-pinned exact app requirement"
        )
        return exactRequirement
    }

    let environmentValue = ProcessInfo.processInfo.environment[
        "CAFFEINE_TEAM_ID"
    ]?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let teamIdentifier = environmentValue,
       let requirement =
        CaffeineIPC.developerIDCodeSigningRequirement(
            identifier: CaffeineIPC.applicationIdentifier,
            teamIdentifier: teamIdentifier
        ) {
        helperLogger.notice(
            "Using anchored Developer ID validation for incoming app connections"
        )
        return requirement
    }

    helperLogger.fault(
        """
        No safe app code requirement was configured. Refusing to expose a \
        privileged XPC service.
        """
    )
    exit(EXIT_FAILURE)
}

guard geteuid() == 0 else {
    helperLogger.fault(
        "CaffeineHelper must run as a root LaunchDaemon"
    )
    exit(EXIT_FAILURE)
}

private let ownershipTrackingSetter = OwnershipTrackingSleepDisabledSetter(
    ownershipStore: CaffeineSPIOwnershipStore(),
    systemGetter: {
        var disabled = false
        let settingResult = CaffeineCopySleepDisabled(&disabled)
        guard settingResult == .success else {
            throw PowerSettingError(
                operation: "read",
                result: settingResult
            )
        }
        return disabled
    },
    systemSetter: { disabled in
        let settingResult = CaffeineSetSleepDisabled(disabled)
        guard settingResult == .success else {
            throw PowerSettingError(
                operation: "persist",
                result: settingResult
            )
        }
    }
)

private let coordinator = SleepDisabledLeaseCoordinator(
    setter: ownershipTrackingSetter.setSleepDisabled
)

private let terminationQueue = DispatchQueue(
    label: "tech.46h.caffeine.helper.termination"
)

private let listener = NSXPCListener(
    machServiceName: CaffeineIPC.helperMachServiceName
)

private func makeTerminationSource(
    for signalNumber: Int32
) -> DispatchSourceSignal {
    // Ignore the traditional handler so delivery is routed to the dispatch
    // source. The actual SPI call and logging remain outside signal context.
    _ = Darwin.signal(signalNumber, SIG_IGN)

    let source = DispatchSource.makeSignalSource(
        signal: signalNumber,
        queue: terminationQueue
    )
    source.setEventHandler {
        helperLogger.notice(
            """
            Caffeine helper received signal \(signalNumber); stopping XPC and \
            restoring SleepDisabled
            """
        )
        listener.invalidate()
        coordinator.shutdownSynchronouslyUntilSuccessful()
        exit(EXIT_SUCCESS)
    }
    source.activate()
    return source
}

// Retain both sources for the process lifetime.
private let terminationSources = [
    makeTerminationSource(for: SIGTERM),
    makeTerminationSource(for: SIGINT),
]

private let delegate = ListenerDelegate(coordinator: coordinator)

// The OS enforces this requirement before asking the delegate to accept a
// connection. It must be installed while the listener is still inactive.
listener.setConnectionCodeSigningRequirement(
    applicationCodeSigningRequirement()
)
listener.delegate = delegate
listener.activate()

helperLogger.info("Caffeine privileged helper is accepting connections")
dispatchMain()
