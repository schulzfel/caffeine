import Foundation
import Testing
@testable import CaffeineCore

@Suite("Stored preferences")
@MainActor
struct StoredPreferencesTests {
    @Test
    func testVersionOnePreferencesDecodeAfterAddingSystemAwakeOption() throws {
        let legacyJSON = """
        {
          "version": 1,
          "enabledOptions": ["displayOn", "screenSaver"],
          "waitingForLidApproval": false,
          "didExplainHelperApproval": true
        }
        """

        let decoded = try JSONDecoder().decode(
            StoredPreferences.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.enabledOptions, [.displayOn, .screenSaver])
        XCTAssertFalse(decoded.enabledOptions.contains(.systemAwake))
        XCTAssertTrue(decoded.didExplainHelperApproval)
    }

    @Test
    func testRoundTripForEveryOptionSubset() throws {
        let options = WakeOption.allCases
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mask in 0..<(1 << options.count) {
            let enabled = Set(
                options.enumerated().compactMap { index, option in
                    mask & (1 << index) == 0 ? nil : option
                }
            )
            let original = StoredPreferences(
                enabledOptions: enabled,
                didExplainHelperApproval: true
            )

            let data = try encoder.encode(original)
            let decoded = try decoder.decode(
                StoredPreferences.self,
                from: data
            )

            XCTAssertEqual(decoded, original)
        }
    }

    @Test
    func testPendingApprovalWinsOverEnabledLidOption() {
        let preferences = StoredPreferences(
            enabledOptions: [.displayOn, .lidClosed],
            waitingForLidApproval: true
        )

        XCTAssertEqual(preferences.enabledOptions, [.displayOn])
        XCTAssertTrue(preferences.waitingForLidApproval)
    }

    @Test
    func testNormalizeRepairsMutatedInvalidStateAndVersion() {
        var preferences = StoredPreferences()
        preferences.version = -1
        preferences.enabledOptions = [.lidClosed, .screenSaver]
        preferences.waitingForLidApproval = true

        preferences.normalize()

        XCTAssertEqual(
            preferences.version,
            StoredPreferences.currentVersion
        )
        XCTAssertEqual(preferences.enabledOptions, [.screenSaver])
    }

    @Test
    func testControllerPersistsNormalizedLoadedValue() async {
        var invalid = StoredPreferences()
        invalid.version = 99
        invalid.enabledOptions = [.lidClosed]
        invalid.waitingForLidApproval = true
        let fixture = makeFixture(
            storedPreferences: invalid,
            helperStatus: .requiresApproval
        )

        await fixture.controller.start()

        XCTAssertEqual(fixture.preferences.savedValues.first?.version, 1)
        XCTAssertFalse(
            fixture.preferences.savedValues.first?
                .enabledOptions.contains(.lidClosed) ?? true
        )
        XCTAssertTrue(
            fixture.preferences.savedValues.first?
                .waitingForLidApproval ?? false
        )
    }
}
