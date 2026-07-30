import AppKit
import CaffeineCore
import CaffeineIPC
import Foundation
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationFlow {
        case running
        case ordinaryQuit
        case installerHandoff
        case ready
    }

    private let logger = Logger(
        subsystem: CaffeineIPC.applicationIdentifier,
        category: "Application"
    )

    private var controller: CaffeineController?
    private var menuBarController: MenuBarController?
    private var terminationReplyIsPending = false
    private var terminationFlow = TerminationFlow.running

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
            controller: caffeineController,
            beginInstallerHandoff: { [weak self] preparedInstaller in
                self?.beginInstallerHandoff(
                    preparedInstaller: preparedInstaller
                )
            }
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
        if terminationFlow == .ready {
            return .terminateNow
        }
        if terminationReplyIsPending {
            return .terminateLater
        }

        terminationReplyIsPending = true
        if terminationFlow == .installerHandoff {
            // The handoff coordinator will reply only after Installer has
            // accepted the package URL (or after its failure UI is dismissed).
            return .terminateLater
        }

        terminationFlow = .ordinaryQuit
        Task {
            await prepareForTermination()
            completeTerminationFlow()
        }
        return .terminateLater
    }

    /// Takes exclusive ownership of cleanup and application termination for
    /// the helper-installer handoff.
    ///
    /// This method is intentionally synchronous up to the state transition.
    /// A Quit event arriving on the next run-loop turn therefore receives
    /// `.terminateLater` and cannot release the process-owned package lease
    /// before NSWorkspace confirms that Installer accepted the URL.
    private func beginInstallerHandoff(
        preparedInstaller: PreparedHelperInstaller
    ) {
        guard terminationFlow == .running else {
            return
        }

        terminationFlow = .installerHandoff
        logger.info("Beginning helper Installer handoff")

        Task {
            await prepareForTermination()
            let installerDidOpen = await openInstaller(
                preparedInstaller
            )
            if !installerDidOpen {
                menuBarController?.presentInstallerOpenFailure()
            }
            completeTerminationFlow()
        }
    }

    /// Completes every asynchronous power cleanup before AppKit termination.
    ///
    /// Both ordinary Quit and the helper-installer handoff use this same
    /// coordinator-owned path.
    private func prepareForTermination() async {
        logger.info("Preparing Caffeine for termination")
        await controller?.shutdown()
        logger.info("Caffeine power cleanup is complete")
    }

    private func openInstaller(
        _ preparedInstaller: PreparedHelperInstaller
    ) async -> Bool {
        // The descriptor inside this value must outlive the asynchronous
        // LaunchServices handoff, not merely the initial URL evaluation.
        defer {
            withExtendedLifetime(preparedInstaller) {}
        }

        let logger = logger
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                preparedInstaller.url,
                configuration: configuration
            ) { application, error in
                if let error {
                    logger.error(
                        "Could not open helper Installer: \(String(describing: error), privacy: .public)"
                    )
                }
                continuation.resume(
                    returning: application != nil && error == nil
                )
            }
        }
    }

    /// Finishes exactly one outstanding termination path.
    ///
    /// During a handoff, an external Quit has already received
    /// `.terminateLater`; reply to that request instead of issuing a second
    /// terminate. Without a pending request, initiate termination now that the
    /// asynchronous Installer open has completed.
    private func completeTerminationFlow() {
        guard terminationFlow != .ready else {
            return
        }

        terminationFlow = .ready
        ProcessInfo.processInfo.enableSuddenTermination()
        logger.info("Caffeine is prepared for immediate termination")

        if terminationReplyIsPending {
            terminationReplyIsPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationDidBecomeActive(
        _ notification: Notification
    ) {
        Task {
            await controller?.refreshExternalState()
        }
    }
}
