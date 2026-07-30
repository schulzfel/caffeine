import AppKit
import CaffeineCore
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let releasesURL: URL = {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let destination = version.map {
            "https://github.com/schulzfel/caffeine/releases/tag/v\($0)"
        } ?? "https://github.com/schulzfel/caffeine/releases/latest"
        return URL(string: destination)!
    }()
    private static let activeStatusIconResourceName =
        "CaffeineStatusActiveTemplate"
    private static let inactiveStatusIconResourceName =
        "CaffeineStatusInactiveTemplate"
    private static let statusIconPointSize = NSSize(width: 16, height: 16)

    private let controller: CaffeineController
    private let beginInstallerHandoff:
        @MainActor (PreparedHelperInstaller) -> Void
    private let statusItem: NSStatusItem
    private let activeStatusIcon: NSImage
    private let inactiveStatusIcon: NSImage
    private let menu = NSMenu()

    private var optionItems: [WakeOption: NSMenuItem] = [:]
    private let bulkItem = NSMenuItem()
    private let launchAtLoginItem = NSMenuItem()

    init(
        controller: CaffeineController,
        beginInstallerHandoff:
            @escaping @MainActor (PreparedHelperInstaller) -> Void
    ) {
        self.controller = controller
        self.beginInstallerHandoff = beginInstallerHandoff
        activeStatusIcon = Self.loadStatusIcon(
            named: Self.activeStatusIconResourceName
        )
        inactiveStatusIcon = Self.loadStatusIcon(
            named: Self.inactiveStatusIconResourceName
        )
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        super.init()

        configureStatusItem()
        configureMenu()

        controller.onStateChange = { [weak self] state in
            self?.render(state.menuPresentation)
        }
        controller.onEvent = { [weak self] event in
            self?.handle(event)
        }
        render(controller.state.menuPresentation)
    }

    func revealMenu() {
        NSApp.activate(ignoringOtherApps: true)
        statusItem.button?.performClick(nil)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.image = inactiveStatusIcon
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.toolTip = "Caffeine"
        button.setAccessibilityLabel("Caffeine")
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        for (index, option) in WakeOption.allCases.enumerated() {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(toggleWakeOption(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            optionItems[option] = item
            menu.addItem(item)
        }

        menu.addItem(.separator())

        bulkItem.action = #selector(toggleAll(_:))
        bulkItem.target = self
        menu.addItem(bulkItem)

        menu.addItem(.separator())

        launchAtLoginItem.action = #selector(toggleLaunchAtLogin(_:))
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Caffeine",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task {
            await controller.refreshExternalState()
        }
    }

    private func render(_ presentation: CaffeineMenuPresentation) {
        statusItem.button?.image = presentation.isStatusActive
            ? activeStatusIcon
            : inactiveStatusIcon
        statusItem.button?.toolTip = presentation.isStatusActive
            ? "Caffeine is keeping your Mac awake"
            : "Caffeine is inactive"
        statusItem.button?.setAccessibilityLabel(
            presentation.isStatusActive
                ? "Caffeine, active"
                : "Caffeine, inactive"
        )

        for option in WakeOption.allCases {
            guard let item = optionItems[option],
                  let itemPresentation =
                    presentation.optionItems[option] else {
                continue
            }
            apply(itemPresentation, to: item)
        }

        apply(presentation.bulkItem, to: bulkItem)
        apply(
            presentation.launchAtLoginItem,
            to: launchAtLoginItem
        )
    }

    private static func loadStatusIcon(named resourceName: String) -> NSImage {
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "png"
        ), let image = NSImage(contentsOf: url) else {
            fatalError("The bundled Caffeine menu-bar icon is missing.")
        }

        image.size = statusIconPointSize
        image.isTemplate = true
        return image
    }

    private func apply(
        _ presentation: MenuItemPresentation,
        to item: NSMenuItem
    ) {
        item.title = presentation.title
        item.state = presentation.isOn ? .on : .off
        item.isEnabled = presentation.isEnabled
        item.toolTip = presentation.toolTip

        if #available(macOS 14.4, *) {
            item.subtitle = presentation.subtitle
        }
    }

    private func handle(_ event: CaffeineControllerEvent) {
        switch event {
        case .requestHelperApproval(let showExplanation):
            presentHelperApproval(showExplanation: showExplanation)
        case .requestLaunchAtLoginApproval:
            SMAppService.openSystemSettingsLoginItems()
        case .presentHelperInstallationRequired:
            presentHelperInstallationRequired()
        }
    }

    private func presentHelperApproval(showExplanation: Bool) {
        NSApp.activate(ignoringOtherApps: true)

        if showExplanation {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.icon = NSApp.applicationIconImage
            alert.messageText =
                "Caffeine’s lid helper is turned off"
            alert.informativeText = """
                The helper was already installed with administrator approval, \
                but it is now disabled in Login Items & Extensions. No \
                Accessibility or Automation permission is needed. Caffeine \
                will open Login Items so you can turn the helper back on.
                """
            alert.addButton(withTitle: "Open Login Items")
            alert.runModal()
        }

        SMAppService.openSystemSettingsLoginItems()
    }

    private func presentHelperInstallationRequired() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Install the optional lid helper"
        alert.informativeText = """
            Staying awake with the lid closed needs a small background helper. \
            macOS does not provide an Accessibility or Automation permission \
            for closed-lid sleep control. Its installer is sealed inside this \
            exact Caffeine build.

            Caffeine will verify and prepare the installer, quit, and open \
            macOS Installer. Installer—not Caffeine—asks an administrator to \
            authorize the system-file install; Caffeine never sees the \
            password. After a successful install, Installer reopens Caffeine \
            automatically. Run the installer again after every Caffeine \
            update.
            """
        alert.addButton(withTitle: "Open Installer")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        guard let preparedInstaller =
            HelperInstallerLocator().matchingInstaller() else {
            presentInstallerOpenFailure()
            return
        }

        controller.deferLidRequestForHelperInstallation()
        beginInstallerHandoff(preparedInstaller)
    }

    func presentInstallerOpenFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Couldn’t verify the helper installer"
        alert.informativeText = """
            Caffeine did not open privileged installer code because it could \
            not prepare a valid copy sealed by this running app. Download a \
            fresh copy of this release and replace Caffeine in Applications.
            """
        alert.addButton(withTitle: "Open Downloads")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesURL)
        }
    }

    @objc
    private func toggleWakeOption(_ sender: NSMenuItem) {
        guard WakeOption.allCases.indices.contains(sender.tag) else {
            return
        }
        let option = WakeOption.allCases[sender.tag]
        Task {
            await controller.toggle(option)
        }
    }

    @objc
    private func toggleAll(_ sender: NSMenuItem) {
        Task {
            await controller.toggleAll()
        }
    }

    @objc
    private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        Task {
            await controller.toggleLaunchAtLogin()
        }
    }

    @objc
    private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
