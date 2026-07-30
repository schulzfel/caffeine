import Foundation
import Testing
@testable import CaffeineCore

// Lightweight expectation helpers keep the state-machine matrix compact while
// using Swift Testing rather than XCTest.
func XCTAssertEqual<Value: Equatable>(
    _ actual: @autoclosure () -> Value,
    _ expected: @autoclosure () -> Value,
    _ message: @autoclosure () -> String = ""
) {
    let actualValue = actual()
    let expectedValue = expected()
    _ = message()
    #expect(actualValue == expectedValue)
}

func XCTAssertTrue(
    _ expression: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = ""
) {
    let value = expression()
    _ = message()
    #expect(value)
}

func XCTAssertFalse(
    _ expression: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = ""
) {
    let value = expression()
    _ = message()
    #expect(!value)
}

func XCTAssertNil<Value>(
    _ expression: @autoclosure () -> Value?,
    _ message: @autoclosure () -> String = ""
) {
    let value = expression()
    _ = message()
    #expect(value == nil)
}

func XCTAssertGreaterThanOrEqual<Value: Comparable>(
    _ actual: @autoclosure () -> Value,
    _ expected: @autoclosure () -> Value,
    _ message: @autoclosure () -> String = ""
) {
    let actualValue = actual()
    let expectedValue = expected()
    _ = message()
    #expect(actualValue >= expectedValue)
}

func XCTFail(_ message: String = "") {
    Issue.record(Comment(rawValue: message))
}

enum TestFailure: Error {
    case expected
}

struct PowerCall: Equatable, Hashable {
    let enabled: Bool
    let option: WakeOption
}

final class MockPowerController: PowerControlling {
    private(set) var calls: [PowerCall] = []
    var failuresRemaining: [PowerCall: Int] = [:]
    var failureErrors: [PowerCall: any Error] = [:]

    func failNext(
        enabled: Bool,
        option: WakeOption,
        count: Int = 1,
        error: any Error = TestFailure.expected
    ) {
        let call = PowerCall(enabled: enabled, option: option)
        failuresRemaining[call] = count
        failureErrors[call] = error
    }

    func setEnabled(
        _ enabled: Bool,
        for option: WakeOption
    ) async throws {
        let call = PowerCall(enabled: enabled, option: option)
        calls.append(call)

        if let remaining = failuresRemaining[call], remaining > 0 {
            failuresRemaining[call] = remaining - 1
            throw failureErrors[call] ?? TestFailure.expected
        }
    }
}

final class SuspendingPowerController: PowerControlling {
    private(set) var calls: [PowerCall] = []
    private(set) var suspendedCall: PowerCall?
    private var continuation: CheckedContinuation<Void, Never>?
    var callToSuspend: PowerCall?

    func setEnabled(
        _ enabled: Bool,
        for option: WakeOption
    ) async throws {
        let call = PowerCall(enabled: enabled, option: option)
        calls.append(call)

        guard call == callToSuspend, continuation == nil else {
            return
        }

        suspendedCall = call
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        suspendedCall = nil
        callToSuspend = nil
    }

    func resumeSuspendedCall() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

final class MockHelperRegistration: HelperRegistrationManaging {
    var statusValue: ServiceStatus
    var readiness: HelperReadiness
    var statusAfterEnsure: ServiceStatus?

    private(set) var statusCallCount = 0
    private(set) var ensureCallCount = 0

    init(
        status: ServiceStatus = .notRegistered,
        readiness: HelperReadiness = .unavailable,
        statusAfterEnsure: ServiceStatus? = nil
    ) {
        statusValue = status
        self.readiness = readiness
        self.statusAfterEnsure = statusAfterEnsure
    }

    func status() async -> ServiceStatus {
        statusCallCount += 1
        return statusValue
    }

    func ensureRegistered() async -> HelperReadiness {
        ensureCallCount += 1
        if let statusAfterEnsure {
            statusValue = statusAfterEnsure
        }
        return readiness
    }
}

final class SuspendingHelperRegistration: HelperRegistrationManaging {
    var statusValue: ServiceStatus
    var readiness: HelperReadiness = .unavailable
    var shouldSuspendNextStatus = false

    private(set) var ensureCallCount = 0
    private(set) var isStatusSuspended = false
    private var continuation: CheckedContinuation<ServiceStatus, Never>?

    init(status: ServiceStatus) {
        statusValue = status
    }

    func status() async -> ServiceStatus {
        guard shouldSuspendNextStatus else {
            return statusValue
        }

        shouldSuspendNextStatus = false
        isStatusSuspended = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func ensureRegistered() async -> HelperReadiness {
        ensureCallCount += 1
        return readiness
    }

    func resumeStatus(with status: ServiceStatus) {
        statusValue = status
        isStatusSuspended = false
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: status)
    }
}

final class MockLaunchAtLoginManager: LaunchAtLoginManaging {
    var statusValue: ServiceStatus
    var statusAfterRegister: ServiceStatus
    var statusAfterUnregister: ServiceStatus
    var registerError: Error?
    var unregisterError: Error?

    private(set) var statusCallCount = 0
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(
        status: ServiceStatus = .notRegistered,
        statusAfterRegister: ServiceStatus = .enabled,
        statusAfterUnregister: ServiceStatus = .notRegistered
    ) {
        statusValue = status
        self.statusAfterRegister = statusAfterRegister
        self.statusAfterUnregister = statusAfterUnregister
    }

    func status() async -> ServiceStatus {
        statusCallCount += 1
        return statusValue
    }

    func register() async throws {
        registerCallCount += 1
        statusValue = statusAfterRegister
        if let registerError {
            throw registerError
        }
    }

    func unregister() async throws {
        unregisterCallCount += 1
        statusValue = statusAfterUnregister
        if let unregisterError {
            throw unregisterError
        }
    }
}

@MainActor
final class MockPreferencesStore: PreferencesStoring {
    var value: StoredPreferences
    private(set) var savedValues: [StoredPreferences] = []

    init(_ value: StoredPreferences = StoredPreferences()) {
        self.value = value
    }

    func load() -> StoredPreferences {
        value
    }

    func save(_ preferences: StoredPreferences) {
        value = preferences
        savedValues.append(preferences)
    }
}

@MainActor
struct ControllerFixture {
    let controller: CaffeineController
    let power: MockPowerController
    let helper: MockHelperRegistration
    let launchAtLogin: MockLaunchAtLoginManager
    let preferences: MockPreferencesStore
}

@MainActor
func makeFixture(
    storedPreferences: StoredPreferences = StoredPreferences(),
    helperStatus: ServiceStatus = .notRegistered,
    helperReadiness: HelperReadiness = .unavailable,
    helperStatusAfterEnsure: ServiceStatus? = nil,
    launchAtLoginStatus: ServiceStatus = .notRegistered,
    sleepBeforeLidRestoreRetry: @escaping (Duration) async -> Void = { _ in }
) -> ControllerFixture {
    let power = MockPowerController()
    let helper = MockHelperRegistration(
        status: helperStatus,
        readiness: helperReadiness,
        statusAfterEnsure: helperStatusAfterEnsure
    )
    let launchAtLogin = MockLaunchAtLoginManager(
        status: launchAtLoginStatus
    )
    let preferences = MockPreferencesStore(storedPreferences)
    let controller = CaffeineController(
        powerController: power,
        helperRegistration: helper,
        launchAtLoginManager: launchAtLogin,
        preferencesStore: preferences,
        sleepBeforeLidRestoreRetry: sleepBeforeLidRestoreRetry
    )

    return ControllerFixture(
        controller: controller,
        power: power,
        helper: helper,
        launchAtLogin: launchAtLogin,
        preferences: preferences
    )
}
