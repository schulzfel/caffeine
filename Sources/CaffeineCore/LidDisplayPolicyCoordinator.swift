import Foundation

/// The platform-neutral inputs that determine how Caffeine should treat the
/// displays while lid-closed mode is active.
public struct LidDisplayPolicyInput: Equatable, Sendable {
    public var lidModeEnabled: Bool
    public var lidClosed: Bool
    public var hasExternalDisplay: Bool

    public init(
        lidModeEnabled: Bool = false,
        lidClosed: Bool = false,
        hasExternalDisplay: Bool = false
    ) {
        self.lidModeEnabled = lidModeEnabled
        self.lidClosed = lidClosed
        self.hasExternalDisplay = hasExternalDisplay
    }

    /// A closed Mac without another display is the only topology in which a
    /// global display-idle request is safe. In particular, an external display
    /// may be in active use in clamshell mode and must not be put to sleep.
    public var isEffectivelyHeadless: Bool {
        lidModeEnabled && lidClosed && !hasExternalDisplay
    }
}

/// A monotonically increasing token for one continuous headless interval.
///
/// Platform code must retain this token with asynchronous work and ask the
/// coordinator whether the action is still current immediately before applying
/// it. This prevents a delayed display-idle request from firing after the lid
/// has reopened or an external display has appeared.
public struct LidDisplayPolicyGeneration:
    Equatable,
    Hashable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Side effects emitted by ``LidDisplayPolicyCoordinator``.
///
/// Actions are ordered. An executor should stop at the first failure, surface
/// that failure, and fail safe rather than continuing to a later action. The
/// suspend and restore actions must be idempotent because cleanup may retry
/// them.
public enum LidDisplayPolicyAction: Equatable, Sendable {
    /// Temporarily releases Caffeine's display-sleep assertion and recurring
    /// user-activity effect. The user's selections remain unchanged.
    case suspendCaffeineDisplayEffects(
        generation: LidDisplayPolicyGeneration
    )

    /// Restores the Caffeine display effects selected by the user.
    case restoreCaffeineDisplayEffects(
        generation: LidDisplayPolicyGeneration
    )

    /// Requests immediate display idle after Caffeine's own display effects
    /// have been suspended.
    case requestDisplayIdle(
        generation: LidDisplayPolicyGeneration
    )

    /// Cancels an in-flight request for the specified generation.
    case cancelDisplayIdleRequest(
        generation: LidDisplayPolicyGeneration
    )

    public var generation: LidDisplayPolicyGeneration {
        switch self {
        case let .suspendCaffeineDisplayEffects(generation),
             let .restoreCaffeineDisplayEffects(generation),
             let .requestDisplayIdle(generation),
             let .cancelDisplayIdleRequest(generation):
            return generation
        }
    }

}

public enum LidDisplayPolicyOperation: Equatable, Sendable {
    case suspendCaffeineDisplayEffects
    case restoreCaffeineDisplayEffects
    case requestDisplayIdle
    case cancelDisplayIdleRequest
}

public struct LidDisplayPolicyState: Equatable, Sendable {
    public fileprivate(set) var input: LidDisplayPolicyInput

    /// The desired suspension state of Caffeine's own display effects.
    public var caffeineDisplayEffectsAreSuspended: Bool {
        input.isEffectivelyHeadless
    }

    /// The latest headless interval token, if any interval has occurred.
    public fileprivate(set) var generation: LidDisplayPolicyGeneration?

    /// The generation whose one-shot idle request is still in flight.
    public fileprivate(set) var pendingDisplayIdleGeneration:
        LidDisplayPolicyGeneration?

    public init(
        input: LidDisplayPolicyInput = LidDisplayPolicyInput(),
        generation: LidDisplayPolicyGeneration? = nil,
        pendingDisplayIdleGeneration: LidDisplayPolicyGeneration? = nil
    ) {
        self.input = input
        self.generation = generation
        self.pendingDisplayIdleGeneration =
            pendingDisplayIdleGeneration
    }

    public var lidModeEnabled: Bool {
        input.lidModeEnabled
    }

    public var lidClosed: Bool {
        input.lidClosed
    }

    public var hasExternalDisplay: Bool {
        input.hasExternalDisplay
    }

    public var isEffectivelyHeadless: Bool {
        input.isEffectivelyHeadless
    }
}

/// Reduces lid-mode and display-topology observations into deterministic,
/// generation-gated platform actions.
///
/// Caffeine suppresses its own display effects only while effectively
/// headless. When an external display is present, both the user's selected
/// display effects and the external display are left alone. Attaching an
/// external display while closed exits headless mode; detaching the final
/// external display while closed starts a new headless generation.
public struct LidDisplayPolicyCoordinator: Sendable {
    public private(set) var state: LidDisplayPolicyState

    public init() {
        state = LidDisplayPolicyState()
    }

    /// Reconciles a complete observation and returns ordered side effects.
    ///
    /// Repeating an identical observation is a no-op. Entering a headless
    /// interval emits exactly one idle request for a new generation.
    @discardableResult
    public mutating func update(
        _ input: LidDisplayPolicyInput
    ) -> [LidDisplayPolicyAction] {
        let wasEffectivelyHeadless = state.isEffectivelyHeadless
        state.input = input
        let isEffectivelyHeadless = state.isEffectivelyHeadless

        guard wasEffectivelyHeadless != isEffectivelyHeadless else {
            return []
        }

        if isEffectivelyHeadless {
            let generation = makeGeneration()
            state.generation = generation
            state.pendingDisplayIdleGeneration = generation

            return [
                .suspendCaffeineDisplayEffects(
                    generation: generation
                ),
                .requestDisplayIdle(generation: generation),
            ]
        }

        guard let generation = state.generation else {
            // This cannot occur through the public initializer, but keeping the
            // state normalized makes a future decoded or migrated state safe.
            state.pendingDisplayIdleGeneration = nil
            return []
        }

        var actions: [LidDisplayPolicyAction] = []
        if state.pendingDisplayIdleGeneration == generation {
            actions.append(
                .cancelDisplayIdleRequest(generation: generation)
            )
        }
        state.pendingDisplayIdleGeneration = nil
        actions.append(
            .restoreCaffeineDisplayEffects(generation: generation)
        )
        return actions
    }

    /// Convenience overload for call sites that already hold the three raw
    /// observations.
    @discardableResult
    public mutating func update(
        lidModeEnabled: Bool,
        lidClosed: Bool,
        hasExternalDisplay: Bool
    ) -> [LidDisplayPolicyAction] {
        update(
            LidDisplayPolicyInput(
                lidModeEnabled: lidModeEnabled,
                lidClosed: lidClosed,
                hasExternalDisplay: hasExternalDisplay
            )
        )
    }

    /// Returns whether an emitted action still belongs to the desired state.
    ///
    /// Asynchronous executors should call this immediately before doing work.
    /// It also generation-gates restore/cancel actions, so a late reopen cleanup
    /// cannot undo a newer close transition.
    public func shouldExecute(
        _ action: LidDisplayPolicyAction
    ) -> Bool {
        guard action.generation == state.generation else {
            return false
        }

        switch action {
        case .suspendCaffeineDisplayEffects:
            return state.isEffectivelyHeadless
                && state.caffeineDisplayEffectsAreSuspended

        case .requestDisplayIdle:
            return state.isEffectivelyHeadless
                && state.pendingDisplayIdleGeneration
                    == action.generation

        case .cancelDisplayIdleRequest:
            return !state.isEffectivelyHeadless
                && state.pendingDisplayIdleGeneration == nil

        case .restoreCaffeineDisplayEffects:
            return !state.isEffectivelyHeadless
                && !state.caffeineDisplayEffectsAreSuspended
        }
    }

    /// Consumes the success or failure of a one-shot display-idle request.
    ///
    /// `true` means the result belongs to the current generation and should be
    /// surfaced if it is a failure. `false` identifies a stale result that must
    /// not alter current policy.
    @discardableResult
    public mutating func finishDisplayIdleRequest(
        generation: LidDisplayPolicyGeneration
    ) -> Bool {
        guard state.isEffectivelyHeadless,
              state.generation == generation,
              state.pendingDisplayIdleGeneration == generation else {
            return false
        }

        state.pendingDisplayIdleGeneration = nil
        return true
    }

    private func makeGeneration()
        -> LidDisplayPolicyGeneration
    {
        var rawValue =
            (state.generation?.rawValue ?? 0) &+ 1
        if rawValue == 0 {
            // Reserve zero so logs and diagnostics never confuse a real token
            // with an uninitialized integer.
            rawValue = 1
        }
        return LidDisplayPolicyGeneration(
            rawValue: rawValue
        )
    }
}
