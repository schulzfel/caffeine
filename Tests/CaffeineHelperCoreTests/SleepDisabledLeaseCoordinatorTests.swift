import Foundation
import Testing
@testable import CaffeineHelperCore

@Suite
struct SleepDisabledLeaseCoordinatorTests {
    @Test
    func testStartupAlwaysClearsPersistentSetting() {
        let setter = SetterProbe()

        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)

        #expect(setter.values == [false])
        #expect(
            coordinator.snapshot ==
            SleepDisabledLeaseSnapshot(
                activeLeaseCount: 0,
                requestingLeaseCount: 0,
                appliedValue: false
            )
        )
    }

    @Test
    func testRepeatedRequestsAreIdempotent() {
        let setter = SetterProbe()
        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)
        let lease = coordinator.openConnection()

        #expect(coordinator.setSleepDisabled(true, for: lease))
        #expect(coordinator.setSleepDisabled(true, for: lease))
        #expect(coordinator.setSleepDisabled(false, for: lease))
        #expect(coordinator.setSleepDisabled(false, for: lease))

        #expect(setter.values == [false, true, false])
    }

    @Test
    func testAnyEnabledLeaseKeepsGlobalSettingEnabled() {
        let setter = SetterProbe()
        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)
        let first = coordinator.openConnection()
        let second = coordinator.openConnection()

        #expect(coordinator.setSleepDisabled(true, for: first))
        #expect(coordinator.setSleepDisabled(true, for: second))
        #expect(coordinator.setSleepDisabled(false, for: first))

        #expect(setter.values == [false, true])
        #expect(coordinator.snapshot.requestingLeaseCount == 1)

        #expect(coordinator.setSleepDisabled(false, for: second))
        #expect(setter.values == [false, true, false])
    }

    @Test
    func testInvalidatingLastConnectionForceClears() {
        let setter = SetterProbe()
        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)
        let first = coordinator.openConnection()
        let second = coordinator.openConnection()

        #expect(coordinator.setSleepDisabled(true, for: first))
        #expect(coordinator.invalidateConnection(first))
        #expect(setter.values == [false, true, false])

        #expect(coordinator.invalidateConnection(second))
        #expect(setter.values == [false, true, false, false])
        #expect(coordinator.snapshot.activeLeaseCount == 0)
    }

    @Test
    func testInvalidationIsIdempotent() {
        let setter = SetterProbe()
        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)
        let lease = coordinator.openConnection()

        #expect(coordinator.invalidateConnection(lease))
        #expect(coordinator.invalidateConnection(lease))

        #expect(setter.values == [false, false])
    }

    @Test
    func testFailedEnableRollsBackLeaseAndCanBeRetried() {
        let setter = SetterProbe(failures: [.enable])
        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)
        let lease = coordinator.openConnection()

        #expect(!coordinator.setSleepDisabled(true, for: lease))
        #expect(coordinator.snapshot.requestingLeaseCount == 0)

        #expect(coordinator.setSleepDisabled(true, for: lease))
        #expect(coordinator.snapshot.requestingLeaseCount == 1)
        #expect(setter.values == [false, true, true])
    }

    @Test
    func testFailedDisablePreservesRequestAndCanBeRetried() {
        let setter = SetterProbe()
        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)
        let lease = coordinator.openConnection()

        #expect(coordinator.setSleepDisabled(true, for: lease))
        setter.failNext(.disable)
        #expect(!coordinator.setSleepDisabled(false, for: lease))
        #expect(coordinator.snapshot.requestingLeaseCount == 1)

        #expect(coordinator.setSleepDisabled(false, for: lease))
        #expect(coordinator.snapshot.requestingLeaseCount == 0)
        #expect(setter.values == [false, true, false, false])
    }

    @Test
    func testCleanupPendingDisableKeepsLeaseOffAndSchedulesRepair() {
        let setter = SetterProbe()
        let scheduler = RetrySchedulerProbe()
        let coordinator = SleepDisabledLeaseCoordinator(
            setter: setter.call,
            cleanupRetryDelays: [0.25, 1],
            retryScheduler: scheduler.schedule
        )
        let lease = coordinator.openConnection()

        #expect(coordinator.setSleepDisabled(true, for: lease))
        setter.failNextCleanupPending(.disable)

        #expect(!coordinator.setSleepDisabled(false, for: lease))
        #expect(coordinator.snapshot.requestingLeaseCount == 0)
        #expect(scheduler.delays == [0.25])

        scheduler.runNext()
        #expect(coordinator.snapshot.appliedValue == false)
        #expect(setter.values == [false, true, false, false])
        #expect(scheduler.scheduledCount == 0)
    }

    @Test
    func testCleanupPendingEnableRollsLeaseOffAndSchedulesRepair() {
        let setter = SetterProbe()
        let scheduler = RetrySchedulerProbe()
        let coordinator = SleepDisabledLeaseCoordinator(
            setter: setter.call,
            cleanupRetryDelays: [0.25],
            retryScheduler: scheduler.schedule
        )
        let lease = coordinator.openConnection()
        setter.failNextCleanupPending(.enable)

        #expect(!coordinator.setSleepDisabled(true, for: lease))
        #expect(coordinator.snapshot.requestingLeaseCount == 0)
        #expect(scheduler.delays == [0.25])

        scheduler.runNext()
        #expect(coordinator.snapshot.appliedValue == false)
        #expect(setter.values == [false, true, false])
        #expect(scheduler.scheduledCount == 0)
    }

    @Test
    func testConnectionOpenRetriesFailedStartupClear() {
        let setter = SetterProbe(failures: [.disable])
        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)

        #expect(coordinator.snapshot.appliedValue == nil)

        _ = coordinator.openConnection()

        #expect(setter.values == [false, false])
        #expect(coordinator.snapshot.appliedValue == false)
    }

    @Test
    func testFailedFinalClearRetriesWithoutAnotherClientEvent() {
        let setter = SetterProbe()
        let scheduler = RetrySchedulerProbe()
        let coordinator = SleepDisabledLeaseCoordinator(
            setter: setter.call,
            cleanupRetryDelays: [0.25, 1],
            retryScheduler: scheduler.schedule
        )
        let lease = coordinator.openConnection()

        setter.failNext(.disable)
        #expect(!coordinator.invalidateConnection(lease))
        #expect(scheduler.delays == [0.25])

        scheduler.runNext()
        #expect(coordinator.snapshot.appliedValue == false)
        #expect(setter.values == [false, false, false])
        #expect(scheduler.scheduledCount == 0)
    }

    @Test
    func testCleanupRetryBackoffCapsUntilClearSucceeds() {
        let setter = SetterProbe(
            failures: [.disable, .disable, .disable]
        )
        let scheduler = RetrySchedulerProbe()
        let coordinator = SleepDisabledLeaseCoordinator(
            setter: setter.call,
            cleanupRetryDelays: [0.25, 1],
            retryScheduler: scheduler.schedule
        )

        #expect(scheduler.delays == [0.25])

        scheduler.runNext()
        _ = coordinator.snapshot
        #expect(scheduler.delays == [1])

        scheduler.runNext()
        _ = coordinator.snapshot
        #expect(scheduler.delays == [1])

        scheduler.runNext()
        #expect(coordinator.snapshot.appliedValue == false)
        #expect(setter.values == [false, false, false, false])
        #expect(scheduler.scheduledCount == 0)
    }

    @Test
    func testSuccessfulEnableCancelsStaleCleanupRetry() {
        let setter = SetterProbe(
            failures: [.disable, .disable]
        )
        let scheduler = RetrySchedulerProbe()
        let coordinator = SleepDisabledLeaseCoordinator(
            setter: setter.call,
            cleanupRetryDelays: [0],
            retryScheduler: scheduler.schedule
        )
        let lease = coordinator.openConnection()

        #expect(coordinator.setSleepDisabled(true, for: lease))
        #expect(setter.values == [false, false, true])

        scheduler.runNext()
        #expect(coordinator.snapshot.appliedValue == true)
        #expect(setter.values == [false, false, true])
        #expect(scheduler.scheduledCount == 0)
    }

    @Test
    func testDuplicateInvalidationRetriesFailedFinalClear() {
        let setter = SetterProbe()
        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)
        let lease = coordinator.openConnection()

        setter.failNext(.disable)
        #expect(!coordinator.invalidateConnection(lease))
        #expect(coordinator.snapshot.activeLeaseCount == 0)

        #expect(coordinator.invalidateConnection(lease))
        #expect(coordinator.invalidateConnection(lease))
        #expect(setter.values == [false, false, false])
    }

    @Test
    func testSynchronousShutdownRetriesWithCappedBackoffUntilSuccess() {
        let setter = SetterProbe()
        let coordinator = SleepDisabledLeaseCoordinator(
            setter: setter.call,
            cleanupRetryDelays: [0.25, 1],
            retryScheduler: { _, _ in }
        )
        setter.failNext(.disable)
        setter.failNext(.disable)
        setter.failNext(.disable)
        var delays: [TimeInterval] = []

        coordinator.shutdownSynchronouslyUntilSuccessful {
            delays.append($0)
        }

        #expect(delays == [0.25, 1, 1])
        #expect(setter.values == [false, false, false, false, false])
        #expect(coordinator.snapshot.activeLeaseCount == 0)
        #expect(coordinator.snapshot.appliedValue == false)
    }

    @Test
    func testSynchronousShutdownRejectsSubsequentStateChanges() {
        let setter = SetterProbe()
        let coordinator = SleepDisabledLeaseCoordinator(
            setter: setter.call,
            cleanupRetryDelays: [0],
            retryScheduler: { _, _ in }
        )
        let lease = coordinator.openConnection()
        #expect(coordinator.setSleepDisabled(true, for: lease))

        coordinator.shutdownSynchronouslyUntilSuccessful()

        #expect(!coordinator.setSleepDisabled(true, for: lease))
        #expect(setter.values == [false, true, false])
    }

    @Test
    func testUnknownLeaseRequestFailsWithoutCallingSetter() {
        let setter = SetterProbe()
        let coordinator = SleepDisabledLeaseCoordinator(setter: setter.call)

        #expect(!coordinator.setSleepDisabled(
            true,
            for: SleepDisabledLease()
        ))
        #expect(setter.values == [false])
    }
}

private final class RetrySchedulerProbe: @unchecked Sendable {
    private struct ScheduledRetry {
        let delay: TimeInterval
        let action: SleepDisabledLeaseCoordinator.RetryAction
    }

    private let lock = NSLock()
    private var retries: [ScheduledRetry] = []

    var delays: [TimeInterval] {
        lock.withLock {
            retries.map(\.delay)
        }
    }

    var scheduledCount: Int {
        lock.withLock {
            retries.count
        }
    }

    func schedule(
        delay: TimeInterval,
        action: @escaping SleepDisabledLeaseCoordinator.RetryAction
    ) {
        lock.withLock {
            retries.append(
                ScheduledRetry(delay: delay, action: action)
            )
        }
    }

    func runNext() {
        let action = lock.withLock {
            retries.removeFirst().action
        }
        action()
    }
}

private final class SetterProbe: @unchecked Sendable {
    enum FailurePoint: Equatable {
        case enable
        case disable
    }

    enum ProbeError: Error {
        case injectedFailure
    }

    private(set) var values: [Bool] = []
    private var failures: [FailurePoint]
    private var cleanupPendingFailures: [FailurePoint] = []

    init(failures: [FailurePoint] = []) {
        self.failures = failures
    }

    func failNext(_ point: FailurePoint) {
        failures.append(point)
    }

    func failNextCleanupPending(_ point: FailurePoint) {
        cleanupPendingFailures.append(point)
    }

    func call(_ value: Bool) throws {
        values.append(value)

        let matchingPoint: FailurePoint = value ? .enable : .disable
        if let index = cleanupPendingFailures.firstIndex(
            where: { $0 == matchingPoint }
        ) {
            cleanupPendingFailures.remove(at: index)
            throw SleepDisabledCleanupPendingError(
                operation: "injected partial transaction",
                cleanupError: ProbeError.injectedFailure
            )
        }
        if let index = failures.firstIndex(where: { $0 == matchingPoint }) {
            failures.remove(at: index)
            throw ProbeError.injectedFailure
        }
    }
}
