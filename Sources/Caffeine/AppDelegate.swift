import AppKit
import CaffeineCore
import CaffeineIPC
import Foundation
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: CaffeineIPC.applicationIdentifier,
        category: "Application"
    )

    private var controller: CaffeineController?
    private var menuBarController: MenuBarController?
    private var cleanupIsInProgress = false
    private var cleanupIsComplete = false

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableSuddenTermination()

        let powerController = SystemPowerController()
        let caffeineController = CaffeineController(
            powerController: powerController,
            helperRegistration: HelperRegistrationManager(),
            launchAtLoginManager: LaunchAtLoginManager(),
            preferencesStore: UserDefaultsPreferencesStore()
        )

        controller = caffeineController
        menuBarController = MenuBarController(
            controller: caffeineController
        )

        Task {
            await powerController.setEffectLostHandler {
                [weak caffeineController] option in
                caffeineController?.effectWasLost(option)
            }
            await caffeineController.start()
            logger.info("Caffeine finished launching")
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if cleanupIsComplete {
            return .terminateNow
        }
        if cleanupIsInProgress {
            return .terminateLater
        }

        cleanupIsInProgress = true
        Task {
            await controller?.shutdown()
            cleanupIsComplete = true
            ProcessInfo.processInfo.enableSuddenTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(
        _ notification: Notification
    ) {
        Task {
            await controller?.refreshExternalState()
        }
    }
}
