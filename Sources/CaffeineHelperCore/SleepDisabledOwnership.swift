import Foundation

/// The durable state Caffeine needs to undo its process-global change.
public struct SleepDisabledOwnership: Equatable, Sendable {
    public let priorDisabled: Bool

    public init(priorDisabled: Bool) {
        self.priorDisabled = priorDisabled
    }
}

/// Durable ownership metadata for the process-global `SleepDisabled` setting.
///
/// The production implementation stores this state in a root-owned marker.
/// Tests inject an in-memory store to verify crash-safe operation ordering.
public protocol SleepDisabledOwnershipStoring: Sendable {
    func sleepDisabledOwnership() throws -> SleepDisabledOwnership?
    func establishSleepDisabledOwnership(priorDisabled: Bool) throws
    func relinquishSleepDisabledOwnership() throws
}

/// Marker protocol used by the lease coordinator to distinguish an ordinary
/// failed transition from a partial transaction that still needs repair.
public protocol SleepDisabledCleanupPendingFailure: Error {}

/// A system-setting transaction reached a state that must be reconciled.
///
/// In this state the coordinator must keep the requesting lease disabled and
/// retry the safety cleanup. Rolling the lease back to `true` would suppress
/// that cleanup and could strand Caffeine's durable ownership marker.
public struct SleepDisabledCleanupPendingError:
    LocalizedError,
    SleepDisabledCleanupPendingFailure
{
    public let operation: String
    public let primaryError: Error?
    public let cleanupError: Error

    public init(
        operation: String,
        primaryError: Error? = nil,
        cleanupError: Error
    ) {
        self.operation = operation
        self.primaryError = primaryError
        self.cleanupError = cleanupError
    }

    public var errorDescription: String? {
        if let primaryError {
            return """
            \(operation) requires cleanup after: \(primaryError); cleanup \
            error: \(cleanupError)
            """
        }
        return "\(operation) requires cleanup: \(cleanupError)"
    }
}

/// Applies `SleepDisabled` without overwriting another tool's global setting.
///
/// Enabling is a write-ahead transaction: the current system value is read and
/// stored durably before the setting changes. Clearing performs the inverse
/// ordering, restoring that prior value before removing ownership.
public final class OwnershipTrackingSleepDisabledSetter: @unchecked Sendable {
    public typealias SystemGetter = () throws -> Bool
    public typealias SystemSetter = (Bool) throws -> Void

    private let lock = NSLock()
    private let ownershipStore: SleepDisabledOwnershipStoring
    private let systemGetter: SystemGetter
    private let systemSetter: SystemSetter

    public init(
        ownershipStore: SleepDisabledOwnershipStoring,
        systemGetter: @escaping SystemGetter,
        systemSetter: @escaping SystemSetter
    ) {
        self.ownershipStore = ownershipStore
        self.systemGetter = systemGetter
        self.systemSetter = systemSetter
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
        try lock.withLock {
            if disabled {
                try enable()
            } else {
                try restoreIfOwned()
            }
        }
    }

    private func enable() throws {
        let existingOwnership = try ownershipStore.sleepDisabledOwnership()
        let establishedHere = existingOwnership == nil

        if establishedHere {
            let priorDisabled = try systemGetter()
            try ownershipStore.establishSleepDisabledOwnership(
                priorDisabled: priorDisabled
            )
        }

        do {
            try systemSetter(true)
        } catch let settingError {
            guard establishedHere else {
                throw settingError
            }

            do {
                try ownershipStore.relinquishSleepDisabledOwnership()
            } catch let rollbackError {
                throw SleepDisabledCleanupPendingError(
                    operation: "rolling back failed SleepDisabled enable",
                    primaryError: settingError,
                    cleanupError: rollbackError
                )
            }
            throw settingError
        }
    }

    private func restoreIfOwned() throws {
        guard let ownership =
            try ownershipStore.sleepDisabledOwnership() else {
            return
        }

        try systemSetter(ownership.priorDisabled)
        do {
            try ownershipStore.relinquishSleepDisabledOwnership()
        } catch let removalError {
            throw SleepDisabledCleanupPendingError(
                operation: "removing SleepDisabled ownership marker",
                cleanupError: removalError
            )
        }
    }
}
