import Foundation

/// The user's durable intent for an option.
public enum OptionIntent: Equatable, Sendable {
    case off
    case enabled
    case waitingForApproval
}

/// The state of the process-scoped side effect for an option.
public enum EffectStatus: Equatable, Sendable {
    case inactive
    case applying
    case active
    case removing

    public var isTransitioning: Bool {
        switch self {
        case .applying, .removing:
            return true
        case .inactive, .active:
            return false
        }
    }

    /// Removing an effect is still considered active until removal succeeds.
    public var isEffectivelyActive: Bool {
        switch self {
        case .active, .removing:
            return true
        case .inactive, .applying:
            return false
        }
    }
}

/// A quiet, non-modal problem associated with a keep-awake option.
public enum OptionIssue: Equatable, Sendable {
    case activationFailed
    case deactivationFailed
    /// An active lid lease ended unexpectedly and may become pending approval.
    case helperConnectionLost
    case helperUnavailable
    case helperRequiresInstallation
    case helperNotFound
    case moveToApplications
}

public struct WakeOptionState: Equatable, Sendable {
    public var intent: OptionIntent
    public var effect: EffectStatus
    public var issue: OptionIssue?

    public init(
        intent: OptionIntent = .off,
        effect: EffectStatus = .inactive,
        issue: OptionIssue? = nil
    ) {
        self.intent = intent
        self.effect = effect
        self.issue = issue
    }
}

/// A normalized representation of a launchd or Service Management status.
public enum ServiceStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

public enum ExternalServiceIssue: Equatable, Sendable {
    case changeFailed
    case moveToApplications
}

public struct ExternalToggleState: Equatable, Sendable {
    public var status: ServiceStatus
    public var isChanging: Bool
    public var issue: ExternalServiceIssue?

    public init(
        status: ServiceStatus = .notRegistered,
        isChanging: Bool = false,
        issue: ExternalServiceIssue? = nil
    ) {
        self.status = status
        self.isChanging = isChanging
        self.issue = issue
    }
}

public enum AppLifecycle: Equatable, Sendable {
    case starting
    case running
    case quitting
}

public struct CaffeineState: Equatable, Sendable {
    public var options: [WakeOption: WakeOptionState]
    public var helperStatus: ServiceStatus
    public var launchAtLogin: ExternalToggleState
    public var lifecycle: AppLifecycle
    public var bulkOperationInProgress: Bool

    public init(
        options: [WakeOption: WakeOptionState] = CaffeineState.emptyOptions,
        helperStatus: ServiceStatus = .notRegistered,
        launchAtLogin: ExternalToggleState = ExternalToggleState(),
        lifecycle: AppLifecycle = .starting,
        bulkOperationInProgress: Bool = false
    ) {
        var normalizedOptions = CaffeineState.emptyOptions
        for option in WakeOption.allCases {
            if let value = options[option] {
                normalizedOptions[option] = value
            }
        }

        self.options = normalizedOptions
        self.helperStatus = helperStatus
        self.launchAtLogin = launchAtLogin
        self.lifecycle = lifecycle
        self.bulkOperationInProgress = bulkOperationInProgress
    }

    public static var emptyOptions: [WakeOption: WakeOptionState] {
        Dictionary(
            uniqueKeysWithValues: WakeOption.allCases.map {
                ($0, WakeOptionState())
            }
        )
    }

    public subscript(_ option: WakeOption) -> WakeOptionState {
        get { options[option] ?? WakeOptionState() }
        set { options[option] = newValue }
    }

    public var hasActiveWakeOption: Bool {
        WakeOption.allCases.contains { self[$0].effect.isEffectivelyActive }
    }

    public var hasTransitioningWakeOption: Bool {
        WakeOption.allCases.contains { self[$0].effect.isTransitioning }
    }
}
