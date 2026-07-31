import CoreGraphics
import Darwin
import Foundation

struct DisplayEnvironmentSnapshot: Equatable, Sendable {
    let hasOnlineExternalDisplay: Bool
}

struct DisplayEnvironmentObservationFailure:
    LocalizedError,
    Equatable,
    Sendable
{
    let message: String

    init(message: String) {
        self.message = message
    }

    fileprivate init(error: any Error) {
        message = error.localizedDescription
    }

    var errorDescription: String? {
        message
    }
}

enum DisplayEnvironmentObservationEvent: Equatable, Sendable {
    case snapshot(DisplayEnvironmentSnapshot)
    case configurationBegan
    case failure(DisplayEnvironmentObservationFailure)
}

protocol DisplayEnvironmentReading {
    func currentSnapshot() throws -> DisplayEnvironmentSnapshot
}

enum DisplayEnvironmentError: LocalizedError {
    case onlineDisplayEnumerationFailed(CGError)
    case reconfigurationRegistrationFailed(CGError)
    case alreadyObserving

    var errorDescription: String? {
        switch self {
        case let .onlineDisplayEnumerationFailed(error):
            return """
                Could not enumerate online displays \
                (CoreGraphics error \(error.rawValue)).
                """
        case let .reconfigurationRegistrationFailed(error):
            return """
                Could not observe display changes \
                (CoreGraphics error \(error.rawValue)).
                """
        case .alreadyObserving:
            return "Display-environment observation is already active."
        }
    }
}

struct CoreGraphicsDisplayEnvironmentReader:
    DisplayEnvironmentReading,
    Sendable
{
    func currentSnapshot() throws -> DisplayEnvironmentSnapshot {
        let hasExternalDisplay = try copyOnlineDisplayIDs()
            .contains { display in
                CGDisplayIsBuiltin(display) == 0
            }
        return DisplayEnvironmentSnapshot(
            hasOnlineExternalDisplay: hasExternalDisplay
        )
    }
}

protocol BuiltInDisplaySleepReading: Sendable {
    /// Returns true when every online built-in display is asleep. A closed
    /// built-in panel can disappear from the online list, which is also a
    /// successful sleeping state.
    func builtInDisplayIsAsleep() throws -> Bool
}

struct CoreGraphicsBuiltInDisplaySleepReader:
    BuiltInDisplaySleepReading,
    Sendable
{
    func builtInDisplayIsAsleep() throws -> Bool {
        try copyOnlineDisplayIDs().allSatisfy { display in
            CGDisplayIsBuiltin(display) == 0 ||
                CGDisplayIsAsleep(display) != 0
        }
    }
}

private func copyOnlineDisplayIDs() throws -> [CGDirectDisplayID] {
    var displayCount: UInt32 = 0
    var result = CGGetOnlineDisplayList(
        0,
        nil,
        &displayCount
    )
    guard result == .success else {
        throw DisplayEnvironmentError
            .onlineDisplayEnumerationFailed(result)
    }

    guard displayCount > 0 else {
        return []
    }

    // The display topology can change between the count and list calls. Retry
    // with the newly reported count rather than truncating the list.
    for _ in 0..<3 {
        var displays = Array(
            repeating: CGDirectDisplayID(0),
            count: Int(displayCount)
        )
        var actualDisplayCount: UInt32 = 0

        result = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetOnlineDisplayList(
                UInt32(buffer.count),
                buffer.baseAddress,
                &actualDisplayCount
            )
        }
        guard result == .success else {
            throw DisplayEnvironmentError
                .onlineDisplayEnumerationFailed(result)
        }

        guard actualDisplayCount <= displays.count else {
            displayCount = actualDisplayCount
            continue
        }
        if Int(actualDisplayCount) < displays.count {
            displays.removeLast(
                displays.count - Int(actualDisplayCount)
            )
        }
        return displays
    }

    // A rapidly changing topology should be reported as an enumeration
    // failure rather than incorrectly claiming that no external display
    // exists.
    throw DisplayEnvironmentError
        .onlineDisplayEnumerationFailed(.failure)
}

protocol DisplayEnvironmentObserving: AnyObject {
    /// Starts observing and asynchronously delivers the current environment
    /// followed by topology changes on a private serial queue. A configuration
    /// begin event lets consumers cancel pending display work before the final
    /// display list exists.
    func start(
        handler:
            @escaping @Sendable (
                DisplayEnvironmentObservationEvent
            ) -> Void
    ) throws

    func stop()
}

final class CoreGraphicsDisplayEnvironmentObserver:
    DisplayEnvironmentObserving,
    @unchecked Sendable
{
    private final class CallbackContext: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(
            label: "com.schulzfel.caffeine.display-environment"
        )
        private let reader: any DisplayEnvironmentReading
        private let handler:
            @Sendable (DisplayEnvironmentObservationEvent) -> Void

        private var isActive = true
        private var isInitialized = false
        private var pendingSnapshot: DisplayEnvironmentSnapshot?
        private var lastDeliveredSnapshot: DisplayEnvironmentSnapshot?
        private var lastDeliveredFailure:
            DisplayEnvironmentObservationFailure?
        private var configurationIsInProgress = false

        init(
            reader: any DisplayEnvironmentReading,
            handler:
                @escaping @Sendable (
                    DisplayEnvironmentObservationEvent
                ) -> Void
        ) {
            self.reader = reader
            self.handler = handler
        }

        func initialize(with snapshot: DisplayEnvironmentSnapshot) {
            queue.async { [self] in
                let eventToDeliver:
                    DisplayEnvironmentObservationEvent?

                lock.lock()
                if isActive, !isInitialized {
                    isInitialized = true
                    if configurationIsInProgress ||
                        lastDeliveredFailure != nil {
                        pendingSnapshot = snapshot
                        eventToDeliver = nil
                    } else {
                        let initialSnapshot =
                            pendingSnapshot ?? snapshot
                        pendingSnapshot = nil
                        lastDeliveredSnapshot = initialSnapshot
                        lastDeliveredFailure = nil
                        eventToDeliver = .snapshot(initialSnapshot)
                    }
                } else {
                    eventToDeliver = nil
                }
                lock.unlock()

                if let eventToDeliver {
                    handler(eventToDeliver)
                }
            }
        }

        func displayConfigurationBegan() {
            queue.async { [self] in
                let eventToDeliver:
                    DisplayEnvironmentObservationEvent?

                lock.lock()
                if isActive, !configurationIsInProgress {
                    configurationIsInProgress = true
                    eventToDeliver = .configurationBegan
                } else {
                    eventToDeliver = nil
                }
                lock.unlock()

                if let eventToDeliver {
                    handler(eventToDeliver)
                }
            }
        }

        func displayConfigurationCompleted() {
            queue.async { [self] in
                guard isStillActive() else {
                    return
                }

                let result: Result<
                    DisplayEnvironmentSnapshot,
                    DisplayEnvironmentObservationFailure
                >
                do {
                    result = .success(
                        try reader.currentSnapshot()
                    )
                } catch {
                    result = .failure(
                        DisplayEnvironmentObservationFailure(
                            error: error
                        )
                    )
                }

                let eventToDeliver:
                    DisplayEnvironmentObservationEvent?

                lock.lock()
                let completedConfiguration =
                    configurationIsInProgress
                configurationIsInProgress = false

                guard isActive else {
                    lock.unlock()
                    return
                }

                switch result {
                case let .success(snapshot):
                    if !isInitialized {
                        pendingSnapshot = snapshot
                        eventToDeliver = nil
                    } else if !completedConfiguration,
                              snapshot == lastDeliveredSnapshot,
                              lastDeliveredFailure == nil {
                        eventToDeliver = nil
                    } else {
                        pendingSnapshot = nil
                        lastDeliveredSnapshot = snapshot
                        lastDeliveredFailure = nil
                        eventToDeliver = .snapshot(snapshot)
                    }

                case let .failure(failure):
                    if !completedConfiguration,
                       failure == lastDeliveredFailure {
                        eventToDeliver = nil
                    } else {
                        lastDeliveredFailure = failure
                        eventToDeliver = .failure(failure)
                    }
                }
                lock.unlock()

                if let eventToDeliver {
                    handler(eventToDeliver)
                }
            }
        }

        func deactivate() {
            lock.lock()
            isActive = false
            pendingSnapshot = nil
            lock.unlock()
        }

        private func isStillActive() -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }
            return isActive
        }
    }

    private struct Registration {
        let token: UUID
        let context: CallbackContext
    }

    private let lifecycleLock = NSLock()
    private let reader: any DisplayEnvironmentReading
    private var registration: Registration?

    init(
        reader: any DisplayEnvironmentReading =
            CoreGraphicsDisplayEnvironmentReader()
    ) {
        self.reader = reader
    }

    func start(
        handler:
            @escaping @Sendable (
                DisplayEnvironmentObservationEvent
            ) -> Void
    ) throws {
        lifecycleLock.lock()
        defer {
            lifecycleLock.unlock()
        }

        guard registration == nil else {
            throw DisplayEnvironmentError.alreadyObserving
        }

        // Match the lid observer's read-register-read startup behavior so an
        // attach or detach cannot disappear between initial state and callback
        // registration.
        _ = try reader.currentSnapshot()
        let context = CallbackContext(
            reader: reader,
            handler: handler
        )
        let token = try DisplayReconfigurationHub.shared.subscribe {
            signal in
            switch signal {
            case .began:
                context.displayConfigurationBegan()
            case .completed:
                context.displayConfigurationCompleted()
            }
        }

        do {
            let stateAfterRegistration = try reader.currentSnapshot()
            registration = Registration(
                token: token,
                context: context
            )
            context.initialize(with: stateAfterRegistration)
        } catch {
            DisplayReconfigurationHub.shared.unsubscribe(token)
            context.deactivate()
            throw error
        }
    }

    func stop() {
        let registrationToRemove: Registration?

        lifecycleLock.lock()
        registrationToRemove = registration
        registration = nil
        lifecycleLock.unlock()

        guard let registrationToRemove else {
            return
        }

        registrationToRemove.context.deactivate()
        DisplayReconfigurationHub.shared.unsubscribe(
            registrationToRemove.token
        )
    }

    deinit {
        stop()
    }
}

private final class DisplayReconfigurationHub: @unchecked Sendable {
    enum Signal: Sendable {
        case began
        case completed
    }

    static let shared = DisplayReconfigurationHub()

    private let lock = NSRecursiveLock()
    private var callbacks:
        [UUID: @Sendable (Signal) -> Void] = [:]
    private var isRegisteredWithCoreGraphics = false

    func subscribe(
        _ callback: @escaping @Sendable (Signal) -> Void
    ) throws -> UUID {
        lock.lock()
        defer {
            lock.unlock()
        }

        let token = UUID()
        callbacks[token] = callback

        if !isRegisteredWithCoreGraphics {
            let result = CGDisplayRegisterReconfigurationCallback(
                caffeineDisplayReconfigurationCallback,
                nil
            )
            guard result == .success else {
                callbacks[token] = nil
                throw DisplayEnvironmentError
                    .reconfigurationRegistrationFailed(result)
            }
            isRegisteredWithCoreGraphics = true
        }

        return token
    }

    func unsubscribe(_ token: UUID) {
        lock.lock()
        defer {
            lock.unlock()
        }

        callbacks[token] = nil
        guard callbacks.isEmpty, isRegisteredWithCoreGraphics else {
            return
        }

        let result = CGDisplayRemoveReconfigurationCallback(
            caffeineDisplayReconfigurationCallback,
            nil
        )
        if result == .success {
            isRegisteredWithCoreGraphics = false
        }
    }

    func notifySubscribers(_ signal: Signal) {
        let callbacksToNotify:
            [@Sendable (Signal) -> Void]

        lock.lock()
        callbacksToNotify = Array(callbacks.values)
        lock.unlock()

        for callback in callbacksToNotify {
            callback(signal)
        }
    }
}

private func caffeineDisplayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    let signal: DisplayReconfigurationHub.Signal =
        flags.contains(.beginConfigurationFlag)
            ? .began
            : .completed
    DisplayReconfigurationHub.shared.notifySubscribers(signal)
}

struct LidDisplayEnvironmentState: Equatable, Sendable {
    let clamshellState: ClamshellState
    let hasOnlineExternalDisplay: Bool
}

enum LidDisplayEnvironmentEvent: Equatable, Sendable {
    case state(LidDisplayEnvironmentState)
    case displayConfigurationBegan
    case observationFailed(DisplayEnvironmentObservationFailure)
}

protocol LidDisplayEnvironmentObserving: AnyObject {
    func start(
        handler:
            @escaping @Sendable (LidDisplayEnvironmentEvent) -> Void
    ) throws

    func stop()
}

/// Combines clamshell and display-topology streams. This makes attaching or
/// detaching an external monitor while the lid is already closed observable
/// without requiring callers to implement their own cross-thread join.
final class MacLidDisplayEnvironmentObserver:
    LidDisplayEnvironmentObserving,
    @unchecked Sendable
{
    private final class StateContext: @unchecked Sendable {
        private let lock = NSLock()
        private let deliveryQueue = DispatchQueue(
            label: "com.schulzfel.caffeine.lid-display-environment"
        )
        private let handler:
            @Sendable (LidDisplayEnvironmentEvent) -> Void

        private var isActive = true
        private var clamshellState: ClamshellState?
        private var displayEnvironment: DisplayEnvironmentSnapshot?
        private var displayEnvironmentIsValid = false
        private var lastDeliveredState: LidDisplayEnvironmentState?

        init(
            handler:
                @escaping @Sendable (
                    LidDisplayEnvironmentEvent
                ) -> Void
        ) {
            self.handler = handler
        }

        func update(clamshellState: ClamshellState) {
            let eventToDeliver: LidDisplayEnvironmentEvent?

            lock.lock()
            if isActive {
                self.clamshellState = clamshellState
                eventToDeliver = makeStateEvent(force: false)
            } else {
                eventToDeliver = nil
            }
            if let eventToDeliver {
                enqueueDelivery(eventToDeliver)
            }
            lock.unlock()
        }

        func update(
            displayEnvironment: DisplayEnvironmentSnapshot
        ) {
            let eventToDeliver: LidDisplayEnvironmentEvent?

            lock.lock()
            if isActive {
                let isRecoveringFromInvalidEnvironment =
                    !displayEnvironmentIsValid
                self.displayEnvironment = displayEnvironment
                displayEnvironmentIsValid = true
                eventToDeliver = makeStateEvent(
                    force: isRecoveringFromInvalidEnvironment
                )
            } else {
                eventToDeliver = nil
            }
            if let eventToDeliver {
                enqueueDelivery(eventToDeliver)
            }
            lock.unlock()
        }

        func displayConfigurationBegan() {
            lock.lock()
            let shouldDeliver =
                isActive && displayEnvironmentIsValid
            if isActive {
                // Invalidate the joined state immediately. A lid change racing
                // the attach must not re-emit a stale headless topology.
                displayEnvironmentIsValid = false
            }
            if shouldDeliver {
                enqueueDelivery(.displayConfigurationBegan)
            }
            lock.unlock()
        }

        func observationFailed(
            _ failure: DisplayEnvironmentObservationFailure
        ) {
            lock.lock()
            let shouldDeliver = isActive
            if isActive {
                displayEnvironmentIsValid = false
            }
            if shouldDeliver {
                enqueueDelivery(.observationFailed(failure))
            }
            lock.unlock()
        }

        func deactivate() {
            lock.lock()
            isActive = false
            displayEnvironmentIsValid = false
            lock.unlock()
        }

        /// Must be called with `lock` held.
        private func makeStateEvent(
            force: Bool
        ) -> LidDisplayEnvironmentEvent? {
            guard displayEnvironmentIsValid,
                  let clamshellState,
                  let displayEnvironment else {
                return nil
            }

            let newState = LidDisplayEnvironmentState(
                clamshellState: clamshellState,
                hasOnlineExternalDisplay:
                    displayEnvironment.hasOnlineExternalDisplay
            )
            guard force || newState != lastDeliveredState else {
                return nil
            }
            lastDeliveredState = newState
            return .state(newState)
        }

        /// Must be called with `lock` held so delivery order matches the
        /// mutation order across the clamshell and display callback queues.
        private func enqueueDelivery(
            _ event: LidDisplayEnvironmentEvent
        ) {
            deliveryQueue.async { [weak self] in
                guard let self else {
                    return
                }

                lock.lock()
                let shouldDeliver = isActive
                lock.unlock()
                if shouldDeliver {
                    handler(event)
                }
            }
        }
    }

    private let lifecycleLock = NSLock()
    private let clamshellObserver: any ClamshellStateObserving
    private let displayEnvironmentObserver:
        any DisplayEnvironmentObserving
    private var stateContext: StateContext?

    init(
        clamshellObserver: any ClamshellStateObserving =
            IOKitClamshellStateObserver(),
        displayEnvironmentObserver:
            any DisplayEnvironmentObserving =
                CoreGraphicsDisplayEnvironmentObserver()
    ) {
        self.clamshellObserver = clamshellObserver
        self.displayEnvironmentObserver = displayEnvironmentObserver
    }

    func start(
        handler:
            @escaping @Sendable (LidDisplayEnvironmentEvent) -> Void
    ) throws {
        lifecycleLock.lock()
        guard stateContext == nil else {
            lifecycleLock.unlock()
            throw ClamshellStateObservationError.alreadyStarted
        }

        let context = StateContext(handler: handler)
        stateContext = context
        lifecycleLock.unlock()

        do {
            try clamshellObserver.start { state in
                context.update(clamshellState: state)
            }
            try displayEnvironmentObserver.start { event in
                switch event {
                case let .snapshot(environment):
                    context.update(
                        displayEnvironment: environment
                    )
                case .configurationBegan:
                    context.displayConfigurationBegan()
                case let .failure(failure):
                    context.observationFailed(failure)
                }
            }
        } catch {
            context.deactivate()
            clamshellObserver.stop()
            displayEnvironmentObserver.stop()

            lifecycleLock.lock()
            if stateContext === context {
                stateContext = nil
            }
            lifecycleLock.unlock()
            throw error
        }
    }

    func stop() {
        let contextToRemove: StateContext?

        lifecycleLock.lock()
        contextToRemove = stateContext
        stateContext = nil
        lifecycleLock.unlock()

        contextToRemove?.deactivate()
        clamshellObserver.stop()
        displayEnvironmentObserver.stop()
    }

    deinit {
        stop()
    }
}

struct DisplaySleepCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardError: String

    var succeeded: Bool {
        terminationStatus == 0
    }
}

enum DisplaySleepRequestOutcome: Equatable, Sendable {
    case exited(DisplaySleepCommandResult)

    /// Cancellation was requested after `/usr/bin/pmset` successfully
    /// launched. This outcome is delivered only by the process termination
    /// handler, after the child has exited and its output pipes are drained.
    case cancelledAfterLaunch
}

protocol DisplaySleepRequesting {
    func requestDisplaySleep() async throws -> DisplaySleepRequestOutcome
}

/// Requests normal display sleep through Apple's command-line power utility.
/// Process is invoked directly with an exact executable URL and argument list;
/// no shell, PATH lookup, or command-string interpolation is involved.
struct PMSetDisplaySleepRequester:
    DisplaySleepRequesting,
    Sendable
{
    private static let executableURL = URL(
        fileURLWithPath: "/usr/bin/pmset"
    )
    private static let arguments = ["displaysleepnow"]

    func requestDisplaySleep() async throws -> DisplaySleepRequestOutcome {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = Self.executableURL
        process.arguments = Self.arguments

        let standardError = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        let execution = DisplaySleepProcessExecution(
            process: process,
            standardError: standardError
        )
        return try await withTaskCancellationHandler {
            try await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class DisplaySleepProcessExecution: @unchecked Sendable {
    private static let forcedTerminationDelay:
        DispatchTimeInterval = .milliseconds(500)

    private enum State {
        case ready
        case running
        case cancelled
        case finished
    }

    private let lock = NSLock()
    private let process: Process
    private let standardError: Pipe

    private var state = State.ready
    private var continuation:
        CheckedContinuation<DisplaySleepRequestOutcome, Error>?

    init(
        process: Process,
        standardError: Pipe
    ) {
        self.process = process
        self.standardError = standardError
    }

    func run() async throws -> DisplaySleepRequestOutcome {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            switch state {
            case .cancelled:
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            case .ready:
                self.continuation = continuation
                process.terminationHandler = { [weak self] process in
                    self?.processDidTerminate(process)
                }
                do {
                    try process.run()
                    state = .running
                    lock.unlock()
                } catch {
                    let cancellationWonBeforeLaunch =
                        Task.isCancelled
                    state = .finished
                    self.continuation = nil
                    process.terminationHandler = nil
                    lock.unlock()
                    continuation.resume(
                        throwing: cancellationWonBeforeLaunch
                            ? CancellationError()
                            : error
                    )
                }
            case .running, .finished:
                lock.unlock()
                continuation.resume(
                    throwing: CocoaError(.executableLoad)
                )
            }
        }
    }

    func cancel() {
        let processToTerminate: Process?

        lock.lock()
        switch state {
        case .ready:
            state = .cancelled
            processToTerminate = nil
        case .running:
            state = .cancelled
            processToTerminate = process
        case .cancelled, .finished:
            processToTerminate = nil
        }
        lock.unlock()

        if processToTerminate?.isRunning == true {
            processToTerminate?.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Self.forcedTerminationDelay
            ) { [weak self] in
                self?.forceTerminateIfStillRunning()
            }
        }
    }

    private func forceTerminateIfStillRunning() {
        lock.lock()
        let wasCancelled: Bool
        if case .cancelled = state {
            wasCancelled = true
        } else {
            wasCancelled = false
        }
        lock.unlock()

        let processIdentifier = process.processIdentifier
        if wasCancelled,
           process.isRunning,
           processIdentifier > 0 {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private func processDidTerminate(_ process: Process) {
        let continuationToResume:
            CheckedContinuation<DisplaySleepRequestOutcome, Error>?
        let wasCancelled: Bool

        lock.lock()
        continuationToResume = continuation
        continuation = nil
        wasCancelled = state == .cancelled
        state = .finished
        process.terminationHandler = nil
        lock.unlock()

        guard let continuationToResume else {
            return
        }
        if wasCancelled {
            // The command has terminated, so no producer can block on this
            // pipe. Drain without decoding diagnostics that cancellation will
            // intentionally discard.
            _ = standardError.fileHandleForReading.readDataToEndOfFile()
            continuationToResume.resume(
                returning: .cancelledAfterLaunch
            )
        } else {
            let errorData =
                standardError.fileHandleForReading.readDataToEndOfFile()
            let result = DisplaySleepCommandResult(
                terminationStatus: process.terminationStatus,
                standardError: String(
                    decoding: errorData,
                    as: UTF8.self
                )
            )
            continuationToResume.resume(
                returning: .exited(result)
            )
        }
    }
}
