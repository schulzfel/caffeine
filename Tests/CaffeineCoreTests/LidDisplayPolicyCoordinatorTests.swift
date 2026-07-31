import Testing
@testable import CaffeineCore

@Suite("Lid display policy")
struct LidDisplayPolicyCoordinatorTests {
    @Test
    func enteringHeadlessSuspendsEffectsBeforeRequestingIdle() {
        var coordinator = LidDisplayPolicyCoordinator()

        let actions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        let generation = LidDisplayPolicyGeneration(rawValue: 1)
        #expect(
            actions == [
                .suspendCaffeineDisplayEffects(
                    generation: generation
                ),
                .requestDisplayIdle(generation: generation),
            ]
        )
        #expect(coordinator.state.lidModeEnabled)
        #expect(coordinator.state.lidClosed)
        #expect(!coordinator.state.hasExternalDisplay)
        #expect(coordinator.state.isEffectivelyHeadless)
        #expect(
            coordinator.state.caffeineDisplayEffectsAreSuspended
        )
        #expect(
            coordinator.state.pendingDisplayIdleGeneration
                == generation
        )
        #expect(actions.allSatisfy(coordinator.shouldExecute))
    }

    @Test
    func duplicateClosedObservationIsIdempotent() {
        var coordinator = LidDisplayPolicyCoordinator()
        let input = LidDisplayPolicyInput(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        let firstActions = coordinator.update(input)
        let secondActions = coordinator.update(input)
        let thirdActions = coordinator.update(input)

        #expect(firstActions.count == 2)
        #expect(secondActions.isEmpty)
        #expect(thirdActions.isEmpty)
        #expect(
            coordinator.state.generation
                == LidDisplayPolicyGeneration(rawValue: 1)
        )
    }

    @Test
    func externalDisplayPreservesUserDisplayEffects() {
        var coordinator = LidDisplayPolicyCoordinator()

        let actions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: true
        )

        #expect(actions.isEmpty)
        #expect(!coordinator.state.isEffectivelyHeadless)
        #expect(
            !coordinator.state.caffeineDisplayEffectsAreSuspended
        )
        #expect(
            coordinator.state.pendingDisplayIdleGeneration == nil
        )
    }

    @Test
    func detachingLastExternalDisplayWhileClosedEntersHeadless() {
        var coordinator = LidDisplayPolicyCoordinator()
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: true
        )

        let actions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        let generation = LidDisplayPolicyGeneration(rawValue: 1)
        #expect(
            actions == [
                .suspendCaffeineDisplayEffects(
                    generation: generation
                ),
                .requestDisplayIdle(generation: generation),
            ]
        )
        #expect(coordinator.state.isEffectivelyHeadless)
    }

    @Test
    func attachingExternalDisplayWhileClosedCancelsAndRestores() {
        var coordinator = LidDisplayPolicyCoordinator()
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        let actions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: true
        )

        let generation = LidDisplayPolicyGeneration(rawValue: 1)
        #expect(
            actions == [
                .cancelDisplayIdleRequest(generation: generation),
                .restoreCaffeineDisplayEffects(
                    generation: generation
                ),
            ]
        )
        #expect(!coordinator.state.isEffectivelyHeadless)
        #expect(
            !coordinator.state.caffeineDisplayEffectsAreSuspended
        )
        #expect(actions.allSatisfy(coordinator.shouldExecute))
    }

    @Test
    func reopeningLidCancelsAndRestores() {
        var coordinator = LidDisplayPolicyCoordinator()
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        let actions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: false,
            hasExternalDisplay: false
        )

        let generation = LidDisplayPolicyGeneration(rawValue: 1)
        #expect(
            actions == [
                .cancelDisplayIdleRequest(generation: generation),
                .restoreCaffeineDisplayEffects(
                    generation: generation
                ),
            ]
        )
        #expect(!coordinator.state.lidClosed)
        #expect(!coordinator.state.isEffectivelyHeadless)
    }

    @Test
    func disablingLidModeWhileClosedCancelsAndRestores() {
        var coordinator = LidDisplayPolicyCoordinator()
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        let actions = coordinator.update(
            lidModeEnabled: false,
            lidClosed: true,
            hasExternalDisplay: false
        )

        let generation = LidDisplayPolicyGeneration(rawValue: 1)
        #expect(
            actions == [
                .cancelDisplayIdleRequest(generation: generation),
                .restoreCaffeineDisplayEffects(
                    generation: generation
                ),
            ]
        )
        #expect(!coordinator.state.lidModeEnabled)
        #expect(!coordinator.state.isEffectivelyHeadless)
    }

    @Test
    func openRaceInvalidatesPendingCloseActionsAndResult() {
        var coordinator = LidDisplayPolicyCoordinator()
        let closeActions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )
        let generation = LidDisplayPolicyGeneration(rawValue: 1)

        let openActions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: false,
            hasExternalDisplay: false
        )
        let acceptedStaleResult =
            coordinator.finishDisplayIdleRequest(
                generation: generation
            )

        #expect(
            closeActions.allSatisfy {
                !coordinator.shouldExecute($0)
            }
        )
        #expect(!acceptedStaleResult)
        #expect(openActions.allSatisfy(coordinator.shouldExecute))
    }

    @Test
    func idleResultIsAcceptedOnlyOnceForCurrentGeneration() {
        var coordinator = LidDisplayPolicyCoordinator()
        let actions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )
        let generation = LidDisplayPolicyGeneration(rawValue: 1)
        let acceptedFirstResult =
            coordinator.finishDisplayIdleRequest(
                generation: generation
            )
        let acceptedDuplicateResult =
            coordinator.finishDisplayIdleRequest(
                generation: generation
            )

        #expect(acceptedFirstResult)
        #expect(!acceptedDuplicateResult)
        #expect(
            coordinator.state.pendingDisplayIdleGeneration == nil
        )
        #expect(
            !coordinator.shouldExecute(actions[1])
        )
        #expect(
            coordinator.update(
                lidModeEnabled: true,
                lidClosed: true,
                hasExternalDisplay: false
            ).isEmpty
        )
    }

    @Test
    func completedIdleRequestDoesNotNeedCancellationOnReopen() {
        var coordinator = LidDisplayPolicyCoordinator()
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )
        _ = coordinator.finishDisplayIdleRequest(
            generation: LidDisplayPolicyGeneration(rawValue: 1)
        )

        let actions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: false,
            hasExternalDisplay: false
        )

        #expect(
            actions == [
                .restoreCaffeineDisplayEffects(
                    generation:
                        LidDisplayPolicyGeneration(rawValue: 1)
                ),
            ]
        )
    }

    @Test
    func aNewCloseUsesNewGenerationAndRejectsOldWork() {
        var coordinator = LidDisplayPolicyCoordinator()
        let firstCloseActions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: false,
            hasExternalDisplay: false
        )

        let secondCloseActions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        let firstGeneration =
            LidDisplayPolicyGeneration(rawValue: 1)
        let secondGeneration =
            LidDisplayPolicyGeneration(rawValue: 2)
        let acceptedStaleResult =
            coordinator.finishDisplayIdleRequest(
                generation: firstGeneration
            )
        #expect(
            secondCloseActions == [
                .suspendCaffeineDisplayEffects(
                    generation: secondGeneration
                ),
                .requestDisplayIdle(
                    generation: secondGeneration
                ),
            ]
        )
        #expect(
            firstCloseActions.allSatisfy {
                !coordinator.shouldExecute($0)
            }
        )
        #expect(!acceptedStaleResult)
        #expect(
            coordinator.state.generation == secondGeneration
        )
    }

    @Test
    func staleRestoreCannotUndoNewerClose() {
        var coordinator = LidDisplayPolicyCoordinator()
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )
        let openActions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: false,
            hasExternalDisplay: false
        )
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        #expect(
            openActions.allSatisfy {
                !coordinator.shouldExecute($0)
            }
        )
        #expect(
            coordinator.state.caffeineDisplayEffectsAreSuspended
        )
    }

    @Test
    func enablingModeAfterLidAlreadyClosedStartsPolicy() {
        var coordinator = LidDisplayPolicyCoordinator()
        #expect(
            coordinator.update(
                lidModeEnabled: false,
                lidClosed: true,
                hasExternalDisplay: false
            ).isEmpty
        )

        let actions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        #expect(actions.count == 2)
        #expect(coordinator.state.isEffectivelyHeadless)
    }

    @Test
    func displayTopologyChangesWhileLidOpenHaveNoEffect() {
        var coordinator = LidDisplayPolicyCoordinator()

        #expect(
            coordinator.update(
                lidModeEnabled: true,
                lidClosed: false,
                hasExternalDisplay: true
            ).isEmpty
        )
        #expect(
            coordinator.update(
                lidModeEnabled: true,
                lidClosed: false,
                hasExternalDisplay: false
            ).isEmpty
        )
        #expect(
            coordinator.state.generation == nil
        )
    }

    @Test
    func attachDetachWhileClosedStartsFreshHeadlessGeneration() {
        var coordinator = LidDisplayPolicyCoordinator()
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )
        _ = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: true
        )

        let actions = coordinator.update(
            lidModeEnabled: true,
            lidClosed: true,
            hasExternalDisplay: false
        )

        let generation = LidDisplayPolicyGeneration(rawValue: 2)
        #expect(
            actions == [
                .suspendCaffeineDisplayEffects(
                    generation: generation
                ),
                .requestDisplayIdle(generation: generation),
            ]
        )
    }
}
