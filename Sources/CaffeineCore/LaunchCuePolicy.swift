/// Decides whether a launch should point the user to Caffeine's menu-bar item.
///
/// AppKit owns the platform-specific launch-event inspection. Keeping the
/// decision here makes every quiet-launch exception explicit and testable.
public enum LaunchCuePolicy {
    public static let helperInstallerRelaunchArgument =
        "--caffeine-helper-installed"

    public struct Context: Equatable, Sendable {
        public var isDefaultLaunchEvent: Bool
        public var isLoginItemLaunch: Bool
        public var arguments: [String]

        public init(
            isDefaultLaunchEvent: Bool,
            isLoginItemLaunch: Bool,
            arguments: [String]
        ) {
            self.isDefaultLaunchEvent = isDefaultLaunchEvent
            self.isLoginItemLaunch = isLoginItemLaunch
            self.arguments = arguments
        }
    }

    public static func shouldRevealMenu(for context: Context) -> Bool {
        context.isDefaultLaunchEvent
            && !context.isLoginItemLaunch
            && !context.arguments.contains(
                helperInstallerRelaunchArgument
            )
    }
}
