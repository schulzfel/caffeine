import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Caffeine
import CaffeineCore

@Suite("System power controller lid policy")
struct SystemPowerControllerLidTests {
    @Test
    func observesInitialStateBeforeRequestingHelperLease() async throws {
        let timeline = Timeline()
        let observer = LidEnvironmentObserverProbe(timeline: timeline)
        let helper = LidHelperLeaseProbe(
            plans: [.succeed, .succeed],
            timeline: timeline
        )
        let factory = LidHelperFactoryProbe(clients: [helper])
        let controller = makeController(
            observer: observer,
            factory: factory
        )

        let enabling = Task {
            try await controller.setEnabled(true, for: .lidClosed)
        }

        #expect(await eventually { observer.startCount == 1 })
        #expect(factory.makeCount == 0)

        observer.emit(.state(.openWithoutExternalDisplay))

        #expect(await eventually { helper.requests == [true] })
        try await enabling.value
        #expect(
            timeline.snapshot.prefix(2)
                == ["observer.state", "helper.true"]
        )

        try await controller.setEnabled(false, for: .lidClosed)
    }

    @Test
    func observationFailureDuringEnableRollsBackHelperLease() async {
        let observer = LidEnvironmentObserverProbe()
        let helper = LidHelperLeaseProbe(
            plans: [.suspend, .succeed]
        )
        let factory = LidHelperFactoryProbe(clients: [helper])
        let controller = makeController(
            observer: observer,
            factory: factory
        )

        let enabling = Task {
            try await controller.setEnabled(true, for: .lidClosed)
        }
        #expect(await eventually { observer.startCount == 1 })
        observer.emit(.state(.openWithoutExternalDisplay))
        #expect(await eventually { helper.pendingCount == 1 })

        observer.emit(
            .observationFailed(
                DisplayEnvironmentObservationFailure(
                    message: "observer failed"
                )
            )
        )
        #expect(
            await eventually {
                await controller.observedLidFailureForTesting()
                    == "observer failed"
            }
        )
        helper.resumeNext(with: .success(()))

        var didThrow = false
        do {
            try await enabling.value
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(await eventually { helper.requests == [true, false] })
        #expect(observer.stopCount == 1)
        #expect(helper.invalidateCount >= 1)
    }

    @Test(arguments: [DisplayRequestMode.nonzero, .hang])
    func failedDisplaySleepWithdrawsLidMode(
        mode: DisplayRequestMode
    ) async throws {
        let observer = LidEnvironmentObserverProbe(
            initialEvent: .state(.closedWithoutExternalDisplay)
        )
        let helper = LidHelperLeaseProbe(plans: [.succeed, .succeed])
        let factory = LidHelperFactoryProbe(clients: [helper])
        let requester = DisplaySleepRequesterProbe(mode: mode)
        let sleepReader = BuiltInDisplaySleepReaderProbe(
            results: [.asleep]
        )
        let losses = EffectLossRecorder()
        let controller = makeController(
            observer: observer,
            factory: factory,
            requester: requester,
            sleepReader: sleepReader
        )
        await controller.setEffectLostHandler { option, issue in
            losses.append(option: option, issue: issue)
        }

        try await controller.setEnabled(true, for: .lidClosed)

        #expect(await eventually { helper.requests == [true, false] })
        #expect(
            await eventually {
                losses.contains(
                    option: .lidClosed,
                    issue: .displaySleepFailed
                )
            }
        )
        #expect(requester.requestCount == 1)
        #expect(sleepReader.readCount == 0)
        #expect(observer.stopCount == 1)
    }

    @Test
    func completedExternalConfigurationCancelsPendingDisplaySleep()
        async throws
    {
        let observer = LidEnvironmentObserverProbe(
            initialEvent: .state(.closedWithoutExternalDisplay)
        )
        let helper = LidHelperLeaseProbe(plans: [.succeed, .succeed])
        let requester = DisplaySleepRequesterProbe(mode: .succeed)
        let backend = PowerAssertionBackendProbe()
        let controller = makeController(
            observer: observer,
            factory: LidHelperFactoryProbe(clients: [helper]),
            requester: requester,
            backend: backend,
            timing: .test(displayDebounce: 5_000_000_000)
        )

        try await controller.setEnabled(true, for: .lidClosed)
        observer.emit(.displayConfigurationBegan)
        observer.emit(.state(.closedWithExternalDisplay))

        #expect(
            await eventually {
                await controller.observedLidEnvironmentForTesting()
                    == .closedWithExternalDisplay
            }
        )
        #expect(requester.requestCount == 0)
        #expect(backend.userActivityDeclarationCount == 0)

        try await controller.setEnabled(false, for: .lidClosed)
        #expect(requester.requestCount == 0)
        #expect(backend.userActivityDeclarationCount == 0)
    }

    @Test
    func successfulCommandWaitsForBuiltInDisplaySleepConfirmation()
        async throws
    {
        let observer = LidEnvironmentObserverProbe(
            initialEvent: .state(.closedWithoutExternalDisplay)
        )
        let helper = LidHelperLeaseProbe(plans: [.succeed, .succeed])
        let sleepReader = BuiltInDisplaySleepReaderProbe(
            results: [.failure, .awake, .asleep]
        )
        let losses = EffectLossRecorder()
        let controller = makeController(
            observer: observer,
            factory: LidHelperFactoryProbe(clients: [helper]),
            sleepReader: sleepReader
        )
        await controller.setEffectLostHandler { option, issue in
            losses.append(option: option, issue: issue)
        }

        try await controller.setEnabled(true, for: .lidClosed)

        #expect(await eventually { sleepReader.readCount == 3 })
        #expect(helper.requests == [true])
        #expect(
            !losses.contains(
                option: .lidClosed,
                issue: .displaySleepFailed
            )
        )

        try await controller.setEnabled(false, for: .lidClosed)
    }

    @Test
    func unconfirmedBuiltInDisplaySleepWithdrawsLidMode()
        async throws
    {
        let observer = LidEnvironmentObserverProbe(
            initialEvent: .state(.closedWithoutExternalDisplay)
        )
        let helper = LidHelperLeaseProbe(plans: [.succeed, .succeed])
        let sleepReader = BuiltInDisplaySleepReaderProbe(
            results: [.awake],
            fallback: .awake
        )
        let losses = EffectLossRecorder()
        let controller = makeController(
            observer: observer,
            factory: LidHelperFactoryProbe(clients: [helper]),
            sleepReader: sleepReader,
            timing: .test(
                verificationTimeout: 5_000_000,
                verificationPoll: 1_000_000
            )
        )
        await controller.setEffectLostHandler { option, issue in
            losses.append(option: option, issue: issue)
        }

        try await controller.setEnabled(true, for: .lidClosed)

        #expect(await eventually { helper.requests == [true, false] })
        #expect(sleepReader.readCount >= 2)
        #expect(
            losses.contains(
                option: .lidClosed,
                issue: .displaySleepFailed
            )
        )
        #expect(observer.stopCount == 1)
    }

    @Test
    func externalDisplayWakesOnlyAfterCancelledChildTerminates()
        async throws
    {
        let observer = LidEnvironmentObserverProbe(
            initialEvent: .state(.closedWithoutExternalDisplay)
        )
        let helper = LidHelperLeaseProbe(plans: [.succeed, .succeed])
        let requester = DisplaySleepRequesterProbe(mode: .controlled)
        let backend = PowerAssertionBackendProbe()
        let controller = makeController(
            observer: observer,
            factory: LidHelperFactoryProbe(clients: [helper]),
            requester: requester,
            backend: backend
        )

        try await controller.setEnabled(true, for: .lidClosed)
        #expect(await eventually { requester.requestCount == 1 })

        observer.emit(.displayConfigurationBegan)
        observer.emit(.state(.closedWithExternalDisplay))
        #expect(
            await eventually {
                await controller.observedLidEnvironmentForTesting()
                    == .closedWithExternalDisplay
            }
        )
        #expect(backend.userActivityDeclarationCount == 0)

        requester.finishControlledAfterCancellation()
        #expect(
            await eventually {
                backend.userActivityDeclarationCount == 1
                    && backend.userActivityReleaseCount == 1
            }
        )

        observer.emit(.state(.closedWithExternalDisplay))
        try? await Task.sleep(nanoseconds: 5_000_000)
        #expect(backend.userActivityDeclarationCount == 1)

        try await controller.setEnabled(false, for: .lidClosed)
    }

    @Test
    func cancelledChildCanFinishBeforeFinalExternalTopology()
        async throws
    {
        let observer = LidEnvironmentObserverProbe(
            initialEvent: .state(.closedWithoutExternalDisplay)
        )
        let helper = LidHelperLeaseProbe(plans: [.succeed, .succeed])
        let requester = DisplaySleepRequesterProbe(mode: .controlled)
        let backend = PowerAssertionBackendProbe()
        let controller = makeController(
            observer: observer,
            factory: LidHelperFactoryProbe(clients: [helper]),
            requester: requester,
            backend: backend
        )

        try await controller.setEnabled(true, for: .lidClosed)
        #expect(await eventually { requester.requestCount == 1 })

        observer.emit(.displayConfigurationBegan)
        requester.finishControlledAfterCancellation()
        try? await Task.sleep(nanoseconds: 5_000_000)
        #expect(backend.userActivityDeclarationCount == 0)

        observer.emit(.state(.closedWithExternalDisplay))
        #expect(
            await eventually {
                backend.userActivityDeclarationCount == 1
                    && backend.userActivityReleaseCount == 1
            }
        )

        try await controller.setEnabled(false, for: .lidClosed)
    }

    @Test
    func externalAttachDuringSleepVerificationReconcilesOnce()
        async throws
    {
        let observer = LidEnvironmentObserverProbe(
            initialEvent: .state(.closedWithoutExternalDisplay)
        )
        let helper = LidHelperLeaseProbe(plans: [.succeed, .succeed])
        let sleepReader = BuiltInDisplaySleepReaderProbe(
            results: [.awake],
            fallback: .awake
        )
        let backend = PowerAssertionBackendProbe()
        let controller = makeController(
            observer: observer,
            factory: LidHelperFactoryProbe(clients: [helper]),
            sleepReader: sleepReader,
            backend: backend,
            timing: .test(
                verificationTimeout: 5_000_000_000,
                verificationPoll: 5_000_000_000
            )
        )

        try await controller.setEnabled(true, for: .lidClosed)
        #expect(await eventually { sleepReader.readCount == 1 })

        observer.emit(.displayConfigurationBegan)
        observer.emit(.state(.closedWithExternalDisplay))

        #expect(
            await eventually {
                backend.userActivityDeclarationCount == 1
                    && backend.userActivityReleaseCount == 1
            }
        )
        #expect(helper.requests == [true])

        try await controller.setEnabled(false, for: .lidClosed)
    }

    @Test
    func staleDisableCompletionCannotStopNewerSession() async throws {
        let observer = LidEnvironmentObserverProbe(
            initialEvent: .state(.openWithoutExternalDisplay)
        )
        let first = LidHelperLeaseProbe(
            plans: [.succeed, .suspend]
        )
        let recovery = LidHelperLeaseProbe(plans: [.succeed])
        let second = LidHelperLeaseProbe(
            plans: [.succeed, .succeed]
        )
        let factory = LidHelperFactoryProbe(
            clients: [first, recovery, second]
        )
        let controller = makeController(
            observer: observer,
            factory: factory
        )

        try await controller.setEnabled(true, for: .lidClosed)
        let oldDisable = Task {
            try await controller.setEnabled(false, for: .lidClosed)
        }
        #expect(await eventually { first.pendingCount == 1 })

        first.triggerLoss()
        #expect(
            await eventually {
                recovery.requests == [false]
                    && observer.stopCount == 1
            }
        )

        try await controller.setEnabled(true, for: .lidClosed)
        #expect(second.requests == [true])
        #expect(observer.startCount == 2)
        #expect(observer.isActive)

        first.resumeNext(with: .success(()))
        try await oldDisable.value

        #expect(observer.stopCount == 1)
        #expect(observer.isActive)
        #expect(second.invalidateCount == 0)

        try await controller.setEnabled(false, for: .lidClosed)
    }

    @Test
    func unconfirmedHelperClearSuppressesSelectedDisplayEffects()
        async throws
    {
        let observer = LidEnvironmentObserverProbe(
            initialEvent: .state(.closedWithoutExternalDisplay)
        )
        let main = LidHelperLeaseProbe(
            plans: [.succeed, .fail]
        )
        let recovery = LidHelperLeaseProbe(plans: [.suspend])
        let backend = PowerAssertionBackendProbe()
        let controller = makeController(
            observer: observer,
            factory: LidHelperFactoryProbe(
                clients: [main, recovery]
            ),
            backend: backend,
            timing: .test(displayDebounce: 5_000_000_000)
        )

        try await controller.setEnabled(true, for: .displayOn)
        try await controller.setEnabled(true, for: .screenSaver)
        #expect(backend.displayCreationCount == 1)
        #expect(backend.userActivityDeclarationCount == 1)

        try await controller.setEnabled(true, for: .lidClosed)
        #expect(backend.displayReleaseCount == 1)
        #expect(backend.userActivityReleaseCount == 1)

        do {
            try await controller.setEnabled(false, for: .lidClosed)
            Issue.record("Expected the failed helper clear to throw")
        } catch {
            // Expected: recovery now owns the safety hold.
        }
        #expect(await eventually { recovery.pendingCount == 1 })
        #expect(backend.displayCreationCount == 1)
        #expect(backend.userActivityDeclarationCount == 1)
        #expect(observer.stopCount == 0)

        recovery.resumeNext(with: .success(()))
        #expect(
            await eventually {
                backend.displayCreationCount == 2
                    && backend.userActivityDeclarationCount == 2
                    && observer.stopCount == 1
            }
        )

        try await controller.setEnabled(false, for: .displayOn)
        try await controller.setEnabled(false, for: .screenSaver)
    }
}

private extension LidDisplayEnvironmentState {
    static let openWithoutExternalDisplay =
        LidDisplayEnvironmentState(
            clamshellState: .open,
            hasOnlineExternalDisplay: false
        )

    static let closedWithoutExternalDisplay =
        LidDisplayEnvironmentState(
            clamshellState: .closed,
            hasOnlineExternalDisplay: false
        )

    static let closedWithExternalDisplay =
        LidDisplayEnvironmentState(
            clamshellState: .closed,
            hasOnlineExternalDisplay: true
        )
}

private extension SystemPowerControllerTiming {
    static func test(
        displayDebounce: UInt64 = 1_000_000,
        verificationTimeout: UInt64 = 20_000_000,
        verificationPoll: UInt64 = 1_000_000
    ) -> Self {
        var timing = Self.production
        timing.helperReplyTimeoutNanoseconds = 1_000_000_000
        timing.lidEnvironmentTimeoutNanoseconds = 1_000_000_000
        timing.displaySleepDebounceNanoseconds = displayDebounce
        timing.displaySleepTimeoutNanoseconds = 20_000_000
        timing.displaySleepVerificationTimeoutNanoseconds =
            verificationTimeout
        timing.displaySleepVerificationPollNanoseconds =
            verificationPoll
        timing.displayConfigurationTimeoutNanoseconds =
            1_000_000_000
        timing.screenSaverPulseNanoseconds = 60_000_000_000
        timing.recoveryInitialDelayNanoseconds = 1_000_000
        timing.recoveryMaximumDelayNanoseconds = 10_000_000
        return timing
    }
}

private func makeController(
    observer: LidEnvironmentObserverProbe,
    factory: LidHelperFactoryProbe,
    requester: DisplaySleepRequesterProbe =
        DisplaySleepRequesterProbe(mode: .succeed),
    sleepReader: BuiltInDisplaySleepReaderProbe =
        BuiltInDisplaySleepReaderProbe(results: [.asleep]),
    backend: PowerAssertionBackendProbe =
        PowerAssertionBackendProbe(),
    timing: SystemPowerControllerTiming = .test()
) -> SystemPowerController {
    SystemPowerController(
        lidDisplayEnvironmentObserver: observer,
        displaySleepRequester: requester,
        builtInDisplaySleepReader: sleepReader,
        lidHelperClientFactory: factory,
        powerAssertionBackend: backend,
        timing: timing
    )
}

private func eventually(
    attempts: Int = 2_000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return await condition()
}

private final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var snapshot: [String] {
        lock.withLock { entries }
    }

    func append(_ entry: String) {
        lock.withLock {
            entries.append(entry)
        }
    }
}

private final class LidEnvironmentObserverProbe:
    LidDisplayEnvironmentObserving,
    @unchecked Sendable
{
    let timeline: Timeline
    private let initialEvent: LidDisplayEnvironmentEvent?
    private let lock = NSLock()
    private var handler:
        (@Sendable (LidDisplayEnvironmentEvent) -> Void)?
    private var starts = 0
    private var stops = 0

    init(
        initialEvent: LidDisplayEnvironmentEvent? = nil,
        timeline: Timeline = Timeline()
    ) {
        self.initialEvent = initialEvent
        self.timeline = timeline
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    var isActive: Bool {
        lock.withLock { handler != nil }
    }

    func start(
        handler:
            @escaping @Sendable (LidDisplayEnvironmentEvent) -> Void
    ) throws {
        lock.withLock {
            starts += 1
            self.handler = handler
        }
        if let initialEvent {
            record(initialEvent)
            handler(initialEvent)
        }
    }

    func stop() {
        lock.withLock {
            stops += 1
            handler = nil
        }
    }

    func emit(_ event: LidDisplayEnvironmentEvent) {
        let callback = lock.withLock { handler }
        record(event)
        callback?(event)
    }

    private func record(_ event: LidDisplayEnvironmentEvent) {
        if case .state = event {
            timeline.append("observer.state")
        }
    }
}

private final class LidHelperFactoryProbe:
    LidHelperLeaseClientFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var queuedClients: [LidHelperLeaseProbe]
    private var creations = 0

    init(clients: [LidHelperLeaseProbe]) {
        queuedClients = clients
    }

    var makeCount: Int {
        lock.withLock { creations }
    }

    func makeClient(
        lossHandler: @escaping @Sendable () -> Void
    ) -> any LidHelperLeaseClient {
        let client = lock.withLock {
            creations += 1
            precondition(
                !queuedClients.isEmpty,
                "Unexpected helper-client creation"
            )
            return queuedClients.removeFirst()
        }
        client.installLossHandler(lossHandler)
        return client
    }
}

private final class LidHelperLeaseProbe:
    LidHelperLeaseClient,
    @unchecked Sendable
{
    enum Plan: Sendable {
        case succeed
        case fail
        case suspend
    }

    private let lock = NSLock()
    private let timeline: Timeline?
    private var plans: [Plan]
    private var requestedValues: [Bool] = []
    private var pending:
        [CheckedContinuation<Void, Error>] = []
    private var invalidations = 0
    private var lossHandler: (@Sendable () -> Void)?

    init(
        plans: [Plan],
        timeline: Timeline? = nil
    ) {
        self.plans = plans
        self.timeline = timeline
    }

    var requests: [Bool] {
        lock.withLock { requestedValues }
    }

    var pendingCount: Int {
        lock.withLock { pending.count }
    }

    var invalidateCount: Int {
        lock.withLock { invalidations }
    }

    func installLossHandler(
        _ handler: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            lossHandler = handler
        }
    }

    func setSleepDisabled(
        _ disabled: Bool,
        timeoutNanoseconds: UInt64
    ) async throws {
        let plan = lock.withLock {
            requestedValues.append(disabled)
            precondition(!plans.isEmpty, "Unexpected helper request")
            return plans.removeFirst()
        }
        timeline?.append("helper.\(disabled)")

        switch plan {
        case .succeed:
            return
        case .fail:
            throw ProbeFailure.expected
        case .suspend:
            try await withCheckedThrowingContinuation {
                continuation in
                lock.withLock {
                    pending.append(continuation)
                }
            }
        }
    }

    func invalidate() {
        lock.withLock {
            invalidations += 1
        }
    }

    func resumeNext(with result: Result<Void, Error>) {
        let continuation = lock.withLock {
            precondition(!pending.isEmpty, "No helper request pending")
            return pending.removeFirst()
        }
        continuation.resume(with: result)
    }

    func triggerLoss() {
        let callback = lock.withLock { lossHandler }
        callback?()
    }
}

enum DisplayRequestMode: Sendable {
    case succeed
    case nonzero
    case hang
    case controlled
}

private final class DisplaySleepRequesterProbe:
    DisplaySleepRequesting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let mode: DisplayRequestMode
    private var requests = 0
    private var controlledContinuations:
        [CheckedContinuation<DisplaySleepRequestOutcome, Never>] = []

    init(mode: DisplayRequestMode) {
        self.mode = mode
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    func requestDisplaySleep() async throws
        -> DisplaySleepRequestOutcome
    {
        lock.withLock {
            requests += 1
        }
        switch mode {
        case .succeed:
            return .exited(
                DisplaySleepCommandResult(
                    terminationStatus: 0,
                    standardError: ""
                )
            )
        case .nonzero:
            return .exited(
                DisplaySleepCommandResult(
                    terminationStatus: 1,
                    standardError: "simulated pmset failure"
                )
            )
        case .hang:
            do {
                try await Task.sleep(
                    nanoseconds: 60_000_000_000
                )
                return .exited(
                    DisplaySleepCommandResult(
                        terminationStatus: 0,
                        standardError: ""
                    )
                )
            } catch is CancellationError {
                return .cancelledAfterLaunch
            }
        case .controlled:
            return await withCheckedContinuation {
                continuation in
                lock.withLock {
                    controlledContinuations.append(
                        continuation
                    )
                }
            }
        }
    }

    func finishControlledAfterCancellation() {
        let continuation = lock.withLock {
            precondition(
                !controlledContinuations.isEmpty,
                "No controlled display request is pending"
            )
            return controlledContinuations.removeFirst()
        }
        continuation.resume(returning: .cancelledAfterLaunch)
    }
}

private final class BuiltInDisplaySleepReaderProbe:
    BuiltInDisplaySleepReading,
    @unchecked Sendable
{
    enum Result: Sendable {
        case asleep
        case awake
        case failure
    }

    private let lock = NSLock()
    private var queuedResults: [Result]
    private let fallbackResult: Result
    private var reads = 0

    init(
        results: [Result],
        fallback: Result? = nil
    ) {
        precondition(!results.isEmpty)
        queuedResults = results
        fallbackResult = fallback ?? results.last!
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func builtInDisplayIsAsleep() throws -> Bool {
        let result = lock.withLock {
            reads += 1
            if queuedResults.isEmpty {
                return fallbackResult
            }
            return queuedResults.removeFirst()
        }
        switch result {
        case .asleep:
            return true
        case .awake:
            return false
        case .failure:
            throw ProbeFailure.expected
        }
    }
}

private final class PowerAssertionBackendProbe:
    PowerAssertionBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var nextIdentifier: IOPMAssertionID = 1
    private var kindsByIdentifier:
        [IOPMAssertionID: PowerAssertionKind] = [:]
    private var createdKinds: [PowerAssertionKind] = []
    private var releasedKinds: [PowerAssertionKind] = []
    private var userActivityDeclarations = 0

    var displayCreationCount: Int {
        lock.withLock {
            createdKinds.count {
                $0 == .preventUserIdleDisplaySleep
            }
        }
    }

    var displayReleaseCount: Int {
        lock.withLock {
            releasedKinds.count {
                $0 == .preventUserIdleDisplaySleep
            }
        }
    }

    var userActivityDeclarationCount: Int {
        lock.withLock { userActivityDeclarations }
    }

    var userActivityReleaseCount: Int {
        lock.withLock {
            releasedKinds.count {
                $0 == .preventUserIdleSystemSleep
            }
        }
    }

    func createAssertion(
        kind: PowerAssertionKind,
        reason: String,
        operationName: String
    ) throws -> IOPMAssertionID {
        lock.withLock {
            let identifier = allocateIdentifier()
            kindsByIdentifier[identifier] = kind
            createdKinds.append(kind)
            return identifier
        }
    }

    func releaseAssertion(
        _ identifier: IOPMAssertionID,
        operationName: String
    ) throws {
        lock.withLock {
            if let kind = kindsByIdentifier.removeValue(
                forKey: identifier
            ) {
                releasedKinds.append(kind)
            }
        }
    }

    func declareUserActivity(
        reason: String,
        existingIdentifier: IOPMAssertionID?
    ) throws -> IOPMAssertionID {
        lock.withLock {
            userActivityDeclarations += 1
            if let existingIdentifier {
                return existingIdentifier
            }
            let identifier = allocateIdentifier()
            // User activity assertions are released through the same API. Use
            // the system-sleep kind solely as a probe label.
            kindsByIdentifier[identifier] =
                .preventUserIdleSystemSleep
            return identifier
        }
    }

    private func allocateIdentifier() -> IOPMAssertionID {
        defer {
            nextIdentifier += 1
        }
        return nextIdentifier
    }
}

private final class EffectLossRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(WakeOption, OptionIssue)] = []

    func append(option: WakeOption, issue: OptionIssue) {
        lock.withLock {
            entries.append((option, issue))
        }
    }

    func contains(
        option: WakeOption,
        issue: OptionIssue
    ) -> Bool {
        lock.withLock {
            entries.contains {
                $0.0 == option && $0.1 == issue
            }
        }
    }
}

private enum ProbeFailure: Error {
    case expected
}
