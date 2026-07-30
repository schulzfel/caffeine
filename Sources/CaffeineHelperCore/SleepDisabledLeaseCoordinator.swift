import Foundation
import OSLog

/// Identifies one accepted XPC connection.
public struct SleepDisabledLease: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public struct SleepDisabledLeaseSnapshot: Equatable, Sendable {
    public let activeLeaseCount: Int
    public let requestingLeaseCount: Int
    /// The last logical ownership request successfully applied by the injected
    /// setter. A `false` request may restore a recorded physical value of true.
    ///
    /// This is `nil` if the mandatory startup clear did not succeed.
    public let appliedValue: Bool?

    public init(
        activeLeaseCount: Int,
        requestingLeaseCount: Int,
        appliedValue: Bool?
    ) {
        self.activeLeaseCount = activeLeaseCount
        self.requestingLeaseCount = requestingLeaseCount
        self.appliedValue = appliedValue
    }
}

/// Serializes the process-wide `SleepDisabled` setting across XPC clients.
///
/// Each accepted connection receives a lease. The global setting is enabled
/// while at least one live lease requests it, and it is forcibly cleared when
/// the final connection goes away. Ordinary failed request transitions are
/// rolled back so an identical retry still reaches the underlying setter.
/// Partial ownership transactions stay disabled and automatically retry their
/// safety repair with capped backoff while the helper is alive.
public final class SleepDisabledLeaseCoordinator: @unchecked Sendable {
    public typealias Setter = (Bool) throws -> Void
    public typealias RetrySleeper = (_ delay: TimeInterval) -> Void
    public typealias RetryAction = @Sendable () -> Void
    public typealias RetryScheduler = (
        _ delay: TimeInterval,
        _ action: @escaping RetryAction
    ) -> Void

    /// Retry quickly at first, then make one low-cost repair attempt per minute
    /// until the persistent setting is known to be clear.
    public static let defaultCleanupRetryDelays: [TimeInterval] = [
        0.25,
        1,
        5,
        15,
        30,
        60,
    ]

    private let queue = DispatchQueue(
        label: "tech.46h.caffeine.helper.sleep-disabled-leases"
    )
    private let setter: Setter
    private let logger: Logger
    private let cleanupRetryDelays: [TimeInterval]
    private let retryScheduler: RetryScheduler

    private var leases: [SleepDisabledLease: Bool] = [:]
    private var appliedValue: Bool?
    private var forcedClearNeedsRetry = false
    private var cleanupRetryGeneration: UInt = 0
    private var cleanupRetryIndex = 0
    private var cleanupRetryScheduled = false
    private var isTerminating = false

    private enum ApplyOutcome {
        case success
        case failure
        case cleanupPending

        var succeeded: Bool {
            self == .success
        }
    }

    public convenience init(
        setter: @escaping Setter,
        logger: Logger = Logger(
            subsystem: "tech.46h.caffeine.helper",
            category: "Power"
        )
    ) {
        self.init(
            setter: setter,
            cleanupRetryDelays: Self.defaultCleanupRetryDelays,
            retryScheduler: { delay, action in
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + delay,
                    execute: action
                )
            },
            logger: logger
        )
    }

    public init(
        setter: @escaping Setter,
        cleanupRetryDelays: [TimeInterval],
        retryScheduler: @escaping RetryScheduler,
        logger: Logger = Logger(
            subsystem: "tech.46h.caffeine.helper",
            category: "Power"
        )
    ) {
        self.setter = setter
        let sanitizedRetryDelays = cleanupRetryDelays
            .filter(\.isFinite)
            .map { max(0, $0) }
        self.cleanupRetryDelays = sanitizedRetryDelays.isEmpty
            ? [60]
            : sanitizedRetryDelays
        self.retryScheduler = retryScheduler
        self.logger = logger

        // SleepDisabled is persistent system state rather than a process-owned
        // assertion. Always repair a stale value before accepting clients.
        queue.sync {
            forcedClearNeedsRetry = !apply(
                false,
                force: true,
                context: "startup"
            ).succeeded
            updateCleanupRetryScheduling()
        }
    }

    /// Opens a lease for one newly accepted XPC connection.
    public func openConnection() -> SleepDisabledLease {
        queue.sync {
            let lease = SleepDisabledLease()
            leases[lease] = false

            guard !isTerminating else {
                return lease
            }

            // A previous last-client cleanup may have failed. Opening a fresh
            // idle connection is an opportunity to retry that safe state.
            let success = applyDesiredValue(
                force: forcedClearNeedsRetry && !desiredValue,
                context: "connection opened"
            ).succeeded
            if success {
                forcedClearNeedsRetry = false
            }
            updateCleanupRetryScheduling()
            logger.debug(
                "Opened helper connection lease; active leases: \(self.leases.count)"
            )
            return lease
        }
    }

    /// Changes one connection's request.
    ///
    /// Returns `false` for an unknown lease or when the underlying system
    /// setting could not be reconciled. On failure, the lease retains its
    /// previous request so callers can safely retry the same transition.
    @discardableResult
    public func setSleepDisabled(
        _ disabled: Bool,
        for lease: SleepDisabledLease
    ) -> Bool {
        queue.sync {
            guard let previousRequest = leases[lease] else {
                logger.error("Rejected a request for an unknown connection lease")
                return false
            }
            guard !isTerminating else {
                leases[lease] = false
                return false
            }

            leases[lease] = disabled
            let outcome = applyDesiredValue(
                force: forcedClearNeedsRetry && !desiredValue,
                context: "client request"
            )
            guard outcome.succeeded else {
                if outcome == .cleanupPending {
                    // The transaction may have restored the system setting but
                    // failed to remove or durably roll back its marker. Keep
                    // this lease off so the safety repair remains eligible.
                    leases[lease] = false
                    forcedClearNeedsRetry = true
                } else {
                    leases[lease] = previousRequest
                }
                updateCleanupRetryScheduling()
                return false
            }
            forcedClearNeedsRetry = false
            updateCleanupRetryScheduling()
            return true
        }
    }

    /// Invalidates a connection lease. Repeated calls are idempotent, except
    /// that they retry a previous failed reconciliation.
    ///
    /// The last invalidation always performs a real clear call, even if the
    /// coordinator already believes the setting is false.
    @discardableResult
    public func invalidateConnection(_ lease: SleepDisabledLease) -> Bool {
        queue.sync {
            if isTerminating {
                leases.removeValue(forKey: lease)
                return true
            }

            guard leases.removeValue(forKey: lease) != nil else {
                let stateNeedsRetry = appliedValue != desiredValue
                guard forcedClearNeedsRetry || stateNeedsRetry else {
                    return true
                }

                let success = applyDesiredValue(
                    force: forcedClearNeedsRetry && !desiredValue,
                    context: "connection cleanup retry"
                ).succeeded
                if success {
                    forcedClearNeedsRetry = false
                }
                updateCleanupRetryScheduling()
                return success
            }

            let isLastConnection = leases.isEmpty
            let success = applyDesiredValue(
                force: isLastConnection
                    || (forcedClearNeedsRetry && !desiredValue),
                context: isLastConnection
                    ? "last connection invalidated"
                    : "connection invalidated"
            ).succeeded
            if isLastConnection {
                forcedClearNeedsRetry = !success
            } else if success {
                forcedClearNeedsRetry = false
            }
            updateCleanupRetryScheduling()
            logger.debug(
                "Invalidated helper connection lease; active leases: \(self.leases.count)"
            )
            return success
        }
    }

    /// Clears all leases and force-clears the persistent setting.
    @discardableResult
    public func shutdown() -> Bool {
        queue.sync {
            leases.removeAll()
            let success = apply(
                false,
                force: true,
                context: "helper shutdown"
            ).succeeded
            forcedClearNeedsRetry = !success
            updateCleanupRetryScheduling()
            return success
        }
    }

    /// Stops accepting state changes and blocks until ownership is durably
    /// reconciled. Intended for SIGTERM/SIGINT after the XPC listener has been
    /// invalidated. Backoff is capped at the final configured delay.
    public func shutdownSynchronouslyUntilSuccessful(
        sleeper: RetrySleeper = Thread.sleep(forTimeInterval:)
    ) {
        queue.sync {
            isTerminating = true
            leases.removeAll()
            cancelCleanupRetry()
        }

        var retryIndex = 0
        while true {
            let success = queue.sync {
                let success = apply(
                    false,
                    force: true,
                    context: "synchronous helper shutdown"
                ).succeeded
                forcedClearNeedsRetry = !success
                if success {
                    cancelCleanupRetry()
                }
                return success
            }
            if success {
                return
            }

            let delay = cleanupRetryDelays[
                min(retryIndex, cleanupRetryDelays.count - 1)
            ]
            logger.notice(
                """
                Retrying synchronous SleepDisabled restoration in \
                \(delay, privacy: .public) seconds
                """
            )
            sleeper(delay)
            retryIndex = min(
                retryIndex + 1,
                cleanupRetryDelays.count - 1
            )
        }
    }

    public var snapshot: SleepDisabledLeaseSnapshot {
        queue.sync {
            SleepDisabledLeaseSnapshot(
                activeLeaseCount: leases.count,
                requestingLeaseCount: leases.values.lazy.filter { $0 }.count,
                appliedValue: appliedValue
            )
        }
    }

    private var desiredValue: Bool {
        leases.values.contains(true)
    }

    private var cleanupIsNeeded: Bool {
        !desiredValue && (forcedClearNeedsRetry || appliedValue != false)
    }

    private func updateCleanupRetryScheduling() {
        guard !isTerminating else {
            cancelCleanupRetry()
            return
        }
        guard cleanupIsNeeded else {
            cancelCleanupRetry()
            return
        }
        scheduleCleanupRetryIfNeeded()
    }

    private func scheduleCleanupRetryIfNeeded() {
        guard !cleanupRetryScheduled else {
            return
        }

        let delay = cleanupRetryDelays[
            min(cleanupRetryIndex, cleanupRetryDelays.count - 1)
        ]
        cleanupRetryGeneration &+= 1
        let generation = cleanupRetryGeneration
        cleanupRetryScheduled = true

        logger.notice(
            """
            Scheduling SleepDisabled safety clear retry in \
            \(delay, privacy: .public) seconds
            """
        )
        retryScheduler(delay) { [weak self] in
            guard let self else {
                return
            }
            self.queue.async {
                self.performScheduledCleanupRetry(generation: generation)
            }
        }
    }

    private func performScheduledCleanupRetry(generation: UInt) {
        guard cleanupRetryScheduled,
              cleanupRetryGeneration == generation else {
            return
        }

        cleanupRetryScheduled = false
        guard cleanupIsNeeded else {
            cancelCleanupRetry()
            return
        }

        let success = apply(
            false,
            force: true,
            context: "automatic safety retry"
        ).succeeded
        if success {
            forcedClearNeedsRetry = false
            cancelCleanupRetry()
            return
        }

        forcedClearNeedsRetry = true
        cleanupRetryIndex = min(
            cleanupRetryIndex + 1,
            cleanupRetryDelays.count - 1
        )
        scheduleCleanupRetryIfNeeded()
    }

    private func cancelCleanupRetry() {
        cleanupRetryGeneration &+= 1
        cleanupRetryIndex = 0
        cleanupRetryScheduled = false
    }

    private func applyDesiredValue(
        force: Bool,
        context: String
    ) -> ApplyOutcome {
        apply(desiredValue, force: force, context: context)
    }

    private func apply(
        _ value: Bool,
        force: Bool,
        context: String
    ) -> ApplyOutcome {
        if !force, appliedValue == value {
            return .success
        }

        do {
            try setter(value)
            appliedValue = value
            logger.info(
                "Applied SleepDisabled=\(value) during \(context, privacy: .public)"
            )
            return .success
        } catch {
            logger.error(
                """
                Failed to apply SleepDisabled=\(value) during \
                \(context, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
            if error is any SleepDisabledCleanupPendingFailure {
                return .cleanupPending
            }
            return .failure
        }
    }
}
