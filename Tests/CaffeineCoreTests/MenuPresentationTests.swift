import Testing
@testable import CaffeineCore

@Suite("Menu presentation")
struct MenuPresentationTests {
    @Test
    func testEveryActiveSubsetDerivesIconChecksAndBulkTitle() {
        let options = WakeOption.allCases

        for mask in 0..<(1 << options.count) {
            var state = CaffeineState(lifecycle: .running)
            var expectedActive = Set<WakeOption>()

            for (index, option) in options.enumerated()
                where mask & (1 << index) != 0 {
                state[option] = WakeOptionState(
                    intent: .enabled,
                    effect: .active
                )
                expectedActive.insert(option)
            }

            let menu = state.menuPresentation
            XCTAssertEqual(
                menu.isStatusActive,
                !expectedActive.isEmpty,
                "mask \(mask)"
            )
            XCTAssertEqual(
                menu.bulkItem.title,
                expectedActive.isEmpty ? "Enable All" : "Disable All",
                "mask \(mask)"
            )

            for option in options {
                XCTAssertEqual(
                    menu.optionItems[option]?.isOn,
                    expectedActive.contains(option),
                    "mask \(mask), option \(option)"
                )
            }
        }
    }

    @Test
    func testPendingApprovalIsUncheckedWithQuietHint() {
        var state = CaffeineState(lifecycle: .running)
        state[.lidClosed] = WakeOptionState(
            intent: .waitingForApproval,
            effect: .inactive
        )

        let menu = state.menuPresentation

        XCTAssertFalse(menu.isStatusActive)
        XCTAssertEqual(menu.bulkItem.title, "Enable All")
        XCTAssertEqual(menu.optionItems[.lidClosed]?.isOn, false)
        XCTAssertEqual(
            menu.optionItems[.lidClosed]?.subtitle,
            "Helper disabled — click to open Login Items"
        )
        XCTAssertEqual(
            menu.optionItems[.lidClosed]?.toolTip,
            "Helper disabled — click to open Login Items"
        )
    }

    @Test
    func testOptionIssuesDeriveRetryableHints() {
        let cases: [(OptionIssue, String)] = [
            (.activationFailed, "Couldn’t enable — click to retry"),
            (.deactivationFailed, "Couldn’t disable — click to retry"),
            (.helperConnectionLost, "Helper unavailable — click to retry"),
            (.helperUnavailable, "Helper unavailable — click to retry"),
            (.helperRequiresInstallation, "Install helper to enable"),
            (.helperNotFound, "Helper is missing"),
            (.moveToApplications, "Move Caffeine to /Applications"),
        ]

        for (issue, expectedHint) in cases {
            var state = CaffeineState(lifecycle: .running)
            state[.displayOn].issue = issue

            XCTAssertEqual(
                state.menuPresentation.optionItems[.displayOn]?.subtitle,
                expectedHint
            )
            XCTAssertEqual(
                state.menuPresentation.optionItems[.displayOn]?.toolTip,
                expectedHint
            )
        }
    }

    @Test
    func testApplyingDisablesOptionAndBulkAction() {
        var state = CaffeineState(lifecycle: .running)
        state[.displayOn] = WakeOptionState(
            intent: .enabled,
            effect: .applying
        )

        let menu = state.menuPresentation

        XCTAssertEqual(menu.optionItems[.displayOn]?.isOn, false)
        XCTAssertEqual(menu.optionItems[.displayOn]?.isEnabled, false)
        XCTAssertFalse(menu.bulkItem.isEnabled)
    }

    @Test
    func testRemovingRemainsVisiblyActiveUntilSuccess() {
        var state = CaffeineState(lifecycle: .running)
        state[.displayOn] = WakeOptionState(
            intent: .off,
            effect: .removing
        )

        let menu = state.menuPresentation

        XCTAssertTrue(menu.isStatusActive)
        XCTAssertEqual(menu.optionItems[.displayOn]?.isOn, true)
        XCTAssertEqual(menu.bulkItem.title, "Disable All")
    }

    @Test
    func testBulkOperationDisablesAllWakeOptions() {
        var state = CaffeineState(
            lifecycle: .running,
            bulkOperationInProgress: true
        )
        state[.displayOn] = WakeOptionState(
            intent: .enabled,
            effect: .active
        )

        let menu = state.menuPresentation

        for option in WakeOption.allCases {
            XCTAssertEqual(menu.optionItems[option]?.isEnabled, false)
        }
        XCTAssertFalse(menu.bulkItem.isEnabled)
    }

    @Test
    func testQuittingDisablesEveryMutableMenuItem() {
        var state = CaffeineState(lifecycle: .quitting)
        state[.displayOn] = WakeOptionState(
            intent: .enabled,
            effect: .active
        )

        let menu = state.menuPresentation

        for option in WakeOption.allCases {
            XCTAssertEqual(menu.optionItems[option]?.isEnabled, false)
        }
        XCTAssertFalse(menu.bulkItem.isEnabled)
        XCTAssertFalse(menu.launchAtLoginItem.isEnabled)
    }

    @Test
    func testLaunchAtLoginPresentationForExternalStatuses() {
        let cases: [
            (
                status: ServiceStatus,
                isOn: Bool,
                hint: String?
            )
        ] = [
            (.enabled, true, nil),
            (.notRegistered, false, nil),
            (.requiresApproval, false, "Waiting for approval…"),
            (.notFound, false, "Login item is unavailable"),
            (.unknown, false, nil),
        ]

        for item in cases {
            let state = CaffeineState(
                launchAtLogin: ExternalToggleState(status: item.status),
                lifecycle: .running
            )
            let presentation = state.menuPresentation.launchAtLoginItem

            XCTAssertEqual(presentation.isOn, item.isOn)
            XCTAssertEqual(presentation.subtitle, item.hint)
        }
    }

    @Test
    func testLaunchAtLoginMoveHintTakesPrecedenceOverServiceStatus() {
        let state = CaffeineState(
            launchAtLogin: ExternalToggleState(
                status: .notFound,
                issue: .moveToApplications
            ),
            lifecycle: .running
        )

        let presentation = state.menuPresentation.launchAtLoginItem

        XCTAssertEqual(
            presentation.subtitle,
            "Move Caffeine to /Applications"
        )
        XCTAssertEqual(
            presentation.toolTip,
            "Move Caffeine to /Applications"
        )
    }
}
