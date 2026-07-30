import Foundation

/// Performs the real IOKit or XPC side effect for a wake option.
///
/// Implementations must be idempotent: enabling an already-enabled option and
/// disabling an already-disabled option must be safe.
public protocol PowerControlling {
    func setEnabled(_ enabled: Bool, for option: WakeOption) async throws
}

/// Describes a failed platform operation that nevertheless relinquished the
/// app's ownership of the effect.
///
/// This is distinct from an ordinary deactivation failure, where the effect is
/// still known to be active and the checked UI should remain on.
public enum PowerEffectStateError: Error, Equatable, Sendable {
    case noLongerControlled
}

/// The result of lazily registering or reconciling the privileged helper.
public enum HelperReadiness: Equatable, Sendable {
    case ready
    case requiresApproval
    case moveToApplications
    case requiresInstallation
    case missing
    case unavailable
}

/// An operation that requires the canonical system application location.
///
/// The root helper installer pins `/Applications/Caffeine.app`, and the
/// launch-at-login item also needs a stable bundle location.
public enum ApplicationInstallationError:
    LocalizedError,
    Equatable,
    Sendable
{
    case moveToApplications

    public var errorDescription: String? {
        "Move Caffeine to /Applications before enabling this feature."
    }
}

public protocol HelperRegistrationManaging {
    func status() async -> ServiceStatus
    func ensureRegistered() async -> HelperReadiness
}

public protocol LaunchAtLoginManaging {
    func status() async -> ServiceStatus
    func register() async throws
    func unregister() async throws
}

/// The versioned durable state owned by Caffeine.
///
/// Launch-at-login is intentionally absent. `SMAppService` is authoritative
/// for that externally managed setting.
public struct StoredPreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var enabledOptions: Set<WakeOption>
    /// A lid request waiting for helper installation or system approval.
    public var waitingForLidApproval: Bool
    public var didExplainHelperApproval: Bool

    public init(
        version: Int = StoredPreferences.currentVersion,
        enabledOptions: Set<WakeOption> = [],
        waitingForLidApproval: Bool = false,
        didExplainHelperApproval: Bool = false
    ) {
        self.version = version
        self.enabledOptions = enabledOptions
        self.waitingForLidApproval = waitingForLidApproval
        self.didExplainHelperApproval = didExplainHelperApproval
        normalize()
    }

    public mutating func normalize() {
        version = StoredPreferences.currentVersion

        if waitingForLidApproval {
            enabledOptions.remove(.lidClosed)
        }
    }

    public func normalized() -> StoredPreferences {
        var copy = self
        copy.normalize()
        return copy
    }
}

@MainActor
public protocol PreferencesStoring: AnyObject {
    func load() -> StoredPreferences
    func save(_ preferences: StoredPreferences)
}

public enum CaffeineControllerEvent: Equatable, Sendable {
    /// The AppKit layer should open Login Items. The one-sentence explanation
    /// is shown only on the first user-initiated request; subsequent clicks
    /// should take the user straight back to the actionable settings pane.
    case requestHelperApproval(showExplanation: Bool)

    /// Launch at Login is registered but still needs the user's approval in
    /// System Settings. Repeated clicks reopen the actionable pane instead of
    /// silently cancelling the pending registration.
    case requestLaunchAtLoginApproval

    /// Lid-closed mode needs the optional root helper to be installed once by
    /// an administrator. The AppKit layer opens the installer sealed inside
    /// the exact running app.
    case presentHelperInstallationRequired
}
