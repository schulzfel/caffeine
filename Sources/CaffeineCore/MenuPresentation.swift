import Foundation

public struct MenuItemPresentation: Equatable, Sendable {
    public var title: String
    public var isOn: Bool
    public var isEnabled: Bool
    public var subtitle: String?
    public var toolTip: String?

    public init(
        title: String,
        isOn: Bool = false,
        isEnabled: Bool = true,
        subtitle: String? = nil,
        toolTip: String? = nil
    ) {
        self.title = title
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.subtitle = subtitle
        self.toolTip = toolTip
    }
}

public struct CaffeineMenuPresentation: Equatable, Sendable {
    public var isStatusActive: Bool
    public var optionItems: [WakeOption: MenuItemPresentation]
    public var bulkItem: MenuItemPresentation
    public var launchAtLoginItem: MenuItemPresentation

    public init(
        isStatusActive: Bool,
        optionItems: [WakeOption: MenuItemPresentation],
        bulkItem: MenuItemPresentation,
        launchAtLoginItem: MenuItemPresentation
    ) {
        self.isStatusActive = isStatusActive
        self.optionItems = optionItems
        self.bulkItem = bulkItem
        self.launchAtLoginItem = launchAtLoginItem
    }
}

public extension CaffeineState {
    var menuPresentation: CaffeineMenuPresentation {
        let applicationCanChangeState = lifecycle == .running
        let bulkCanRun = applicationCanChangeState
            && !bulkOperationInProgress
            && !hasTransitioningWakeOption

        let optionItems = Dictionary(
            uniqueKeysWithValues: WakeOption.allCases.map { option in
                let optionState = self[option]
                let hint = optionState.menuHint
                let isEnabled = applicationCanChangeState
                    && !bulkOperationInProgress
                    && !optionState.effect.isTransitioning

                return (
                    option,
                    MenuItemPresentation(
                        title: option.title,
                        isOn: optionState.effect.isEffectivelyActive,
                        isEnabled: isEnabled,
                        subtitle: hint,
                        toolTip: hint
                    )
                )
            }
        )

        let launchHint: String?
        if launchAtLogin.issue == .moveToApplications {
            launchHint = "Move Caffeine to /Applications"
        } else {
            switch launchAtLogin.status {
            case .requiresApproval:
                launchHint = "Waiting for approval…"
            case .notFound:
                launchHint = "Login item is unavailable"
            case .unknown where launchAtLogin.issue != nil:
                launchHint = "Couldn’t update login item"
            default:
                launchHint = launchAtLogin.issue == nil
                    ? nil
                    : "Couldn’t update login item"
            }
        }

        return CaffeineMenuPresentation(
            isStatusActive: hasActiveWakeOption,
            optionItems: optionItems,
            bulkItem: MenuItemPresentation(
                title: hasActiveWakeOption ? "Disable All" : "Enable All",
                isEnabled: bulkCanRun
            ),
            launchAtLoginItem: MenuItemPresentation(
                title: "Launch at Login",
                isOn: launchAtLogin.status == .enabled,
                isEnabled: applicationCanChangeState
                    && !launchAtLogin.isChanging,
                subtitle: launchHint,
                toolTip: launchHint
            )
        )
    }
}

private extension WakeOptionState {
    var menuHint: String? {
        if intent == .waitingForApproval {
            return "Helper disabled — click to open Login Items"
        }

        switch issue {
        case .activationFailed:
            return "Couldn’t enable — click to retry"
        case .deactivationFailed:
            return "Couldn’t disable — click to retry"
        case .helperConnectionLost, .helperUnavailable:
            return "Helper unavailable — click to retry"
        case .helperRequiresInstallation:
            return "Install helper to enable"
        case .helperNotFound:
            return "Helper is missing"
        case .moveToApplications:
            return "Move Caffeine to /Applications"
        case nil:
            return nil
        }
    }
}
