import Testing
@testable import CaffeineCore

@Suite("Launch cue policy")
struct LaunchCuePolicyTests {
    @Test
    func testOnlyManualDefaultLaunchesRevealTheMenu() {
        let cases: [
            (
                name: String,
                context: LaunchCuePolicy.Context,
                expected: Bool
            )
        ] = [
            (
                "manual default launch",
                context(),
                true
            ),
            (
                "login item launch",
                context(isLoginItemLaunch: true),
                false
            ),
            (
                "non-default launch event",
                context(isDefaultLaunchEvent: false),
                false
            ),
            (
                "restored launch",
                context(isDefaultLaunchEvent: false),
                false
            ),
            (
                "helper installer relaunch",
                context(
                    arguments: [
                        "/Applications/Caffeine.app/Contents/MacOS/Caffeine",
                        LaunchCuePolicy.helperInstallerRelaunchArgument,
                    ]
                ),
                false
            ),
            (
                "manual launch with unrelated arguments",
                context(arguments: ["Caffeine", "--unrelated"]),
                true
            ),
            (
                "multiple quiet-launch signals",
                context(
                    isLoginItemLaunch: true,
                    arguments: [
                        LaunchCuePolicy.helperInstallerRelaunchArgument
                    ]
                ),
                false
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                LaunchCuePolicy.shouldRevealMenu(for: testCase.context),
                testCase.expected,
                testCase.name
            )
        }
    }

    private func context(
        isDefaultLaunchEvent: Bool = true,
        isLoginItemLaunch: Bool = false,
        arguments: [String] = ["Caffeine"]
    ) -> LaunchCuePolicy.Context {
        LaunchCuePolicy.Context(
            isDefaultLaunchEvent: isDefaultLaunchEvent,
            isLoginItemLaunch: isLoginItemLaunch,
            arguments: arguments
        )
    }
}
