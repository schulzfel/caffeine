import Foundation
import IOKit
import IOKit.pwr_mgt

enum ClamshellState: Equatable, Sendable {
    case open
    case closed

    fileprivate init(isClosed: Bool) {
        self = isClosed ? .closed : .open
    }
}

protocol ClamshellStateObserving: AnyObject {
    /// Starts observing and asynchronously delivers the current state followed
    /// by changes on a private serial queue.
    func start(
        handler: @escaping @Sendable (ClamshellState) -> Void
    ) throws

    func stop()
}

enum ClamshellStateObservationError: LocalizedError {
    case alreadyStarted
    case rootDomainUnavailable
    case notificationPortUnavailable
    case interestRegistrationFailed(IOReturn)
    case stateUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "Clamshell observation is already active."
        case .rootDomainUnavailable:
            return "The IOKit power root domain is unavailable."
        case .notificationPortUnavailable:
            return "IOKit could not create a notification port."
        case let .interestRegistrationFailed(result):
            return """
                IOKit could not register for clamshell changes \
                (result 0x\(String(result, radix: 16))).
                """
        case .stateUnavailable:
            return "This Mac does not expose a clamshell state."
        }
    }
}

/// Observes the public IOPMrootDomain clamshell property and general-interest
/// message. The initial read is intentionally performed both before and after
/// notification registration so a lid transition cannot be lost at startup.
final class IOKitClamshellStateObserver:
    ClamshellStateObserving,
    @unchecked Sendable
{
    private static let rootDomainClassName = "IOPMrootDomain"
    private static let callbackQueueMarker: UInt8 = 1
    // IOPM.h defines this public message as
    // iokit_family_msg(sub_iokit_powermanagement, 0x100). Clang cannot import
    // that nested function-like macro into Swift, so retain its SDK value here.
    fileprivate static let clamshellStateChangeMessage =
        natural_t(0xe003_4100)

    private struct Registration {
        let rootDomain: io_service_t
        let notificationPort: IONotificationPortRef
        let interestNotification: io_object_t
        let callbackQueue: DispatchQueue
        let callbackQueueKey: DispatchSpecificKey<UInt8>
        let contextPointer: UnsafeMutableRawPointer
    }

    fileprivate final class CallbackContext: @unchecked Sendable {
        private let lock = NSLock()
        private let rootDomain: io_service_t
        private let handler: @Sendable (ClamshellState) -> Void

        private var isActive = true
        private var isInitialized = false
        private var pendingState: ClamshellState?
        private var lastDeliveredState: ClamshellState?

        init(
            rootDomain: io_service_t,
            handler: @escaping @Sendable (ClamshellState) -> Void
        ) {
            self.rootDomain = rootDomain
            self.handler = handler
        }

        func initialize(with state: ClamshellState) {
            let stateToDeliver: ClamshellState?

            lock.lock()
            if isActive, !isInitialized {
                isInitialized = true
                stateToDeliver = pendingState ?? state
                pendingState = nil
                lastDeliveredState = stateToDeliver
            } else {
                stateToDeliver = nil
            }
            lock.unlock()

            if let stateToDeliver {
                handler(stateToDeliver)
            }
        }

        func handle(
            messageType: natural_t,
            messageArgument: UnsafeMutableRawPointer?
        ) {
            guard messageType ==
                IOKitClamshellStateObserver
                    .clamshellStateChangeMessage,
                  isStillActive() else {
                return
            }

            // The message documents bit zero as the closed/open state. A fresh
            // registry read also collapses any older queued messages when the
            // lid moves more than once before this callback is serviced.
            let argumentBits = UInt(
                bitPattern: Int(bitPattern: messageArgument)
            )
            let messageState = ClamshellState(
                isClosed:
                    argumentBits & UInt(kClamshellStateBit) != 0
            )
            let currentState =
                IOKitClamshellStateObserver.readState(
                    from: rootDomain
                ) ?? messageState

            let stateToDeliver: ClamshellState?

            lock.lock()
            if !isActive {
                stateToDeliver = nil
            } else if !isInitialized {
                pendingState = currentState
                stateToDeliver = nil
            } else if currentState == lastDeliveredState {
                stateToDeliver = nil
            } else {
                lastDeliveredState = currentState
                stateToDeliver = currentState
            }
            lock.unlock()

            if let stateToDeliver {
                handler(stateToDeliver)
            }
        }

        func deactivate() {
            lock.lock()
            isActive = false
            pendingState = nil
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

    private let lifecycleLock = NSLock()
    private var registration: Registration?

    func start(
        handler: @escaping @Sendable (ClamshellState) -> Void
    ) throws {
        lifecycleLock.lock()
        defer {
            lifecycleLock.unlock()
        }

        guard registration == nil else {
            throw ClamshellStateObservationError.alreadyStarted
        }

        let matching = IOServiceMatching(Self.rootDomainClassName)
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            matching
        )
        guard rootDomain != IO_OBJECT_NULL else {
            throw ClamshellStateObservationError.rootDomainUnavailable
        }

        guard let notificationPort = IONotificationPortCreate(
            kIOMainPortDefault
        ) else {
            IOObjectRelease(rootDomain)
            throw ClamshellStateObservationError
                .notificationPortUnavailable
        }

        let callbackQueue = DispatchQueue(
            label: "com.schulzfel.caffeine.clamshell-observer"
        )
        let callbackQueueKey = DispatchSpecificKey<UInt8>()
        callbackQueue.setSpecific(
            key: callbackQueueKey,
            value: Self.callbackQueueMarker
        )
        IONotificationPortSetDispatchQueue(
            notificationPort,
            callbackQueue
        )

        let context = CallbackContext(
            rootDomain: rootDomain,
            handler: handler
        )
        let contextPointer = Unmanaged.passRetained(context).toOpaque()

        // First half of the read-register-read sequence.
        let stateBeforeRegistration = Self.readState(from: rootDomain)

        var interestNotification = io_object_t(IO_OBJECT_NULL)
        let result = IOServiceAddInterestNotification(
            notificationPort,
            rootDomain,
            kIOGeneralInterest,
            caffeineClamshellInterestCallback,
            contextPointer,
            &interestNotification
        )
        guard result == kIOReturnSuccess else {
            context.deactivate()
            IONotificationPortDestroy(notificationPort)
            IOObjectRelease(rootDomain)
            Unmanaged<CallbackContext>
                .fromOpaque(contextPointer)
                .release()
            throw ClamshellStateObservationError
                .interestRegistrationFailed(result)
        }

        // Second half of the read-register-read sequence. Any notification
        // racing this read is buffered by CallbackContext until initialization.
        let stateAfterRegistration = Self.readState(from: rootDomain)
        guard let initialState =
            stateAfterRegistration ?? stateBeforeRegistration else {
            let failedRegistration = Registration(
                rootDomain: rootDomain,
                notificationPort: notificationPort,
                interestNotification: interestNotification,
                callbackQueue: callbackQueue,
                callbackQueueKey: callbackQueueKey,
                contextPointer: contextPointer
            )
            Self.tearDown(failedRegistration)
            throw ClamshellStateObservationError.stateUnavailable
        }

        registration = Registration(
            rootDomain: rootDomain,
            notificationPort: notificationPort,
            interestNotification: interestNotification,
            callbackQueue: callbackQueue,
            callbackQueueKey: callbackQueueKey,
            contextPointer: contextPointer
        )

        // Keep initial delivery on the same serial queue as every subsequent
        // notification. Callbacks already queued by the registration race run
        // first and are reconciled by the context.
        callbackQueue.async {
            context.initialize(with: initialState)
        }
    }

    func stop() {
        let registrationToRemove: Registration?

        lifecycleLock.lock()
        registrationToRemove = registration
        registration = nil
        lifecycleLock.unlock()

        if let registrationToRemove {
            Self.tearDown(registrationToRemove)
        }
    }

    deinit {
        stop()
    }

    private static func readState(
        from rootDomain: io_service_t
    ) -> ClamshellState? {
        guard let property = IORegistryEntryCreateCFProperty(
            rootDomain,
            kAppleClamshellStateKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }

        guard let number = property as? NSNumber else {
            return nil
        }
        return ClamshellState(isClosed: number.boolValue)
    }

    private static func tearDown(_ registration: Registration) {
        let unmanagedContext = Unmanaged<CallbackContext>.fromOpaque(
            registration.contextPointer
        )
        unmanagedContext.takeUnretainedValue().deactivate()

        if registration.interestNotification != IO_OBJECT_NULL {
            IOObjectRelease(registration.interestNotification)
        }
        IONotificationPortDestroy(registration.notificationPort)

        // IOService callbacks use an unretained refCon. Drain the configured
        // serial queue after unregistering before releasing that retained
        // context. When stop is called by the handler itself, defer the release
        // to the next queue turn instead of synchronously deadlocking.
        if DispatchQueue.getSpecific(
            key: registration.callbackQueueKey
        ) == Self.callbackQueueMarker {
            registration.callbackQueue.async {
                unmanagedContext.release()
                IOObjectRelease(registration.rootDomain)
            }
        } else {
            registration.callbackQueue.sync {}
            unmanagedContext.release()
            IOObjectRelease(registration.rootDomain)
        }
    }
}

private func caffeineClamshellInterestCallback(
    refCon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: natural_t,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refCon else {
        return
    }

    let context = Unmanaged<
        IOKitClamshellStateObserver.CallbackContext
    >
    .fromOpaque(refCon)
    .takeUnretainedValue()
    context.handle(
        messageType: messageType,
        messageArgument: messageArgument
    )
    withExtendedLifetime(context) {}
}
