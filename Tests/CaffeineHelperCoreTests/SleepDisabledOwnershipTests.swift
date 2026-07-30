import Testing
@testable import CaffeineHelperCore

@Suite
struct SleepDisabledOwnershipTests {
    @Test
    func clearWithoutOwnershipDoesNotTouchGlobalSetting() throws {
        let fixture = OwnershipFixture()
        let setter = fixture.makeSetter()

        try setter.setSleepDisabled(false)

        #expect(fixture.events == [.readOwnership])
        #expect(fixture.ownership == nil)
    }

    @Test
    func enableRecordsPriorValueBeforeChangingGlobalSetting() throws {
        let fixture = OwnershipFixture(systemDisabled: false)
        let setter = fixture.makeSetter()

        try setter.setSleepDisabled(true)

        #expect(
            fixture.events == [
                .readOwnership,
                .readSystem,
                .establishOwnership(priorDisabled: false),
                .setSystem(true),
            ]
        )
        #expect(
            fixture.ownership ==
                SleepDisabledOwnership(priorDisabled: false)
        )
    }

    @Test
    func preexistingTrueIsRecordedAndRestored() throws {
        let fixture = OwnershipFixture(systemDisabled: true)
        let setter = fixture.makeSetter()

        try setter.setSleepDisabled(true)
        try setter.setSleepDisabled(false)

        #expect(
            fixture.events == [
                .readOwnership,
                .readSystem,
                .establishOwnership(priorDisabled: true),
                .setSystem(true),
                .readOwnership,
                .setSystem(true),
                .relinquishOwnership,
            ]
        )
        #expect(fixture.systemDisabled)
        #expect(fixture.ownership == nil)
    }

    @Test
    func existingOwnershipRestoresSavedValueWithoutReadingCurrentValue() throws {
        let fixture = OwnershipFixture(
            ownership: SleepDisabledOwnership(priorDisabled: true),
            systemDisabled: false
        )
        let setter = fixture.makeSetter()

        try setter.setSleepDisabled(false)

        #expect(
            fixture.events == [
                .readOwnership,
                .setSystem(true),
                .relinquishOwnership,
            ]
        )
        #expect(fixture.systemDisabled)
    }

    @Test
    func migratedV1OwnershipRestoresHistoricalFalseValue() throws {
        // The C marker reader maps a v1 marker into priorDisabled=false.
        let fixture = OwnershipFixture(
            ownership: SleepDisabledOwnership(priorDisabled: false),
            systemDisabled: true
        )
        let setter = fixture.makeSetter()

        try setter.setSleepDisabled(false)

        #expect(fixture.systemDisabled == false)
        #expect(fixture.ownership == nil)
    }

    @Test
    func failedSystemReadPreventsMarkerAndGlobalMutation() {
        let fixture = OwnershipFixture()
        fixture.failNextSystemRead = true
        let setter = fixture.makeSetter()

        #expect(errorThrown {
            try setter.setSleepDisabled(true)
        } != nil)
        #expect(fixture.events == [.readOwnership, .readSystem])
        #expect(fixture.ownership == nil)
    }

    @Test
    func failedNewEnableRollsOwnershipMarkerBack() {
        let fixture = OwnershipFixture()
        fixture.failNextSystemValue = true
        let setter = fixture.makeSetter()

        #expect(errorThrown {
            try setter.setSleepDisabled(true)
        } != nil)
        #expect(
            fixture.events == [
                .readOwnership,
                .readSystem,
                .establishOwnership(priorDisabled: false),
                .setSystem(true),
                .relinquishOwnership,
            ]
        )
        #expect(fixture.ownership == nil)
    }

    @Test
    func failedEnablePreservesPreexistingOwnership() {
        let fixture = OwnershipFixture(
            ownership: SleepDisabledOwnership(priorDisabled: true)
        )
        fixture.failNextSystemValue = true
        let setter = fixture.makeSetter()

        #expect(errorThrown {
            try setter.setSleepDisabled(true)
        } != nil)
        #expect(
            fixture.events == [
                .readOwnership,
                .setSystem(true),
            ]
        )
        #expect(
            fixture.ownership ==
                SleepDisabledOwnership(priorDisabled: true)
        )
    }

    @Test
    func restoreChangesSystemBeforeRelinquishingOwnership() throws {
        let fixture = OwnershipFixture(
            ownership: SleepDisabledOwnership(priorDisabled: false),
            systemDisabled: true
        )
        let setter = fixture.makeSetter()

        try setter.setSleepDisabled(false)

        #expect(
            fixture.events == [
                .readOwnership,
                .setSystem(false),
                .relinquishOwnership,
            ]
        )
        #expect(fixture.ownership == nil)
    }

    @Test
    func failedRestoreRetainsOwnershipForStartupRepair() {
        let fixture = OwnershipFixture(
            ownership: SleepDisabledOwnership(priorDisabled: false),
            systemDisabled: true
        )
        fixture.failNextSystemValue = false
        let setter = fixture.makeSetter()

        #expect(errorThrown {
            try setter.setSleepDisabled(false)
        } != nil)
        #expect(
            fixture.events == [
                .readOwnership,
                .setSystem(false),
            ]
        )
        #expect(fixture.ownership != nil)
    }

    @Test
    func markerRemovalFailureHasDistinctCleanupPendingError() {
        let fixture = OwnershipFixture(
            ownership: SleepDisabledOwnership(priorDisabled: false),
            systemDisabled: true
        )
        fixture.failNextRelinquish = true
        let setter = fixture.makeSetter()

        let error = errorThrown {
            try setter.setSleepDisabled(false)
        }

        #expect(error is SleepDisabledCleanupPendingFailure)
        #expect(fixture.systemDisabled == false)
        #expect(fixture.ownership != nil)
    }

    @Test
    func failedEnableRollbackHasDistinctCleanupPendingError() {
        let fixture = OwnershipFixture()
        fixture.failNextSystemValue = true
        fixture.failNextRelinquish = true
        let setter = fixture.makeSetter()

        let error = errorThrown {
            try setter.setSleepDisabled(true)
        }

        #expect(error is SleepDisabledCleanupPendingFailure)
        #expect(fixture.ownership != nil)
    }

    @Test
    func markerRemovalFailureIsRetryableAfterSuccessfulRestore() {
        let fixture = OwnershipFixture(
            ownership: SleepDisabledOwnership(priorDisabled: true)
        )
        fixture.failNextRelinquish = true
        let setter = fixture.makeSetter()

        #expect(errorThrown {
            try setter.setSleepDisabled(false)
        } != nil)
        #expect(fixture.ownership != nil)

        #expect(errorThrown {
            try setter.setSleepDisabled(false)
        } == nil)
        #expect(fixture.ownership == nil)
    }

    @Test
    func ownershipEstablishFailurePreventsGlobalEnable() {
        let fixture = OwnershipFixture()
        fixture.failNextEstablish = true
        let setter = fixture.makeSetter()

        #expect(errorThrown {
            try setter.setSleepDisabled(true)
        } != nil)
        #expect(
            fixture.events == [
                .readOwnership,
                .readSystem,
                .establishOwnership(priorDisabled: false),
            ]
        )
        #expect(fixture.ownership == nil)
    }
}

private func errorThrown(
    _ operation: () throws -> Void
) -> Error? {
    do {
        try operation()
        return nil
    } catch {
        return error
    }
}

private enum OwnershipEvent: Equatable {
    case readOwnership
    case readSystem
    case establishOwnership(priorDisabled: Bool)
    case setSystem(Bool)
    case relinquishOwnership
}

private enum OwnershipTestError: Error {
    case injectedFailure
}

private final class OwnershipFixture: @unchecked Sendable {
    var ownership: SleepDisabledOwnership?
    var systemDisabled: Bool
    var events: [OwnershipEvent] = []
    var failNextSystemRead = false
    var failNextSystemValue: Bool?
    var failNextEstablish = false
    var failNextRelinquish = false

    init(
        ownership: SleepDisabledOwnership? = nil,
        systemDisabled: Bool = false
    ) {
        self.ownership = ownership
        self.systemDisabled = systemDisabled
    }

    func makeSetter() -> OwnershipTrackingSleepDisabledSetter {
        OwnershipTrackingSleepDisabledSetter(
            ownershipStore: OwnershipStore(fixture: self),
            systemGetter: readSystem,
            systemSetter: setSystem
        )
    }

    func readOwnership() -> SleepDisabledOwnership? {
        events.append(.readOwnership)
        return ownership
    }

    func readSystem() throws -> Bool {
        events.append(.readSystem)
        if failNextSystemRead {
            failNextSystemRead = false
            throw OwnershipTestError.injectedFailure
        }
        return systemDisabled
    }

    func establishOwnership(priorDisabled: Bool) throws {
        events.append(
            .establishOwnership(priorDisabled: priorDisabled)
        )
        if failNextEstablish {
            failNextEstablish = false
            throw OwnershipTestError.injectedFailure
        }
        ownership = SleepDisabledOwnership(
            priorDisabled: priorDisabled
        )
    }

    func relinquishOwnership() throws {
        events.append(.relinquishOwnership)
        if failNextRelinquish {
            failNextRelinquish = false
            throw OwnershipTestError.injectedFailure
        }
        ownership = nil
    }

    func setSystem(_ disabled: Bool) throws {
        events.append(.setSystem(disabled))
        if failNextSystemValue == disabled {
            failNextSystemValue = nil
            throw OwnershipTestError.injectedFailure
        }
        systemDisabled = disabled
    }
}

private struct OwnershipStore: SleepDisabledOwnershipStoring {
    let fixture: OwnershipFixture

    func sleepDisabledOwnership() throws -> SleepDisabledOwnership? {
        fixture.readOwnership()
    }

    func establishSleepDisabledOwnership(
        priorDisabled: Bool
    ) throws {
        try fixture.establishOwnership(
            priorDisabled: priorDisabled
        )
    }

    func relinquishSleepDisabledOwnership() throws {
        try fixture.relinquishOwnership()
    }
}
