import CaffeineCore
import CaffeineIPC
import CaffeineLaunchdSupport
import Foundation
import OSLog
import ServiceManagement

private let caffeineDaemonPlistName =
    "tech.46h.caffeine.helper.plist"
private let caffeineInstalledDaemonURL = URL(
    fileURLWithPath:
        "/Library/LaunchDaemons/\(caffeineDaemonPlistName)",
    isDirectory: false
)
private let caffeineInstalledHelperURL = URL(
    fileURLWithPath:
        "/Library/PrivilegedHelperTools/tech.46h.caffeine.helper",
    isDirectory: false
)

private func isInstalledApplicationBundle(_ bundle: Bundle) -> Bool {
    let url = bundle.bundleURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
    return url.path == "/Applications/Caffeine.app"
}

@MainActor
final class HelperRegistrationManager: HelperRegistrationManaging {
    private let bundle: Bundle
    private let fileManager: FileManager
    private let launchdInspector: LegacyLaunchdJobInspector
    private let logger: Logger

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        launchdInspector: LegacyLaunchdJobInspector =
            LegacyLaunchdJobInspector(),
        logger: Logger = Logger(
            subsystem: "tech.46h.caffeine",
            category: "HelperRegistration"
        )
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.launchdInspector = launchdInspector
        self.logger = logger
    }

    func status() async -> ServiceStatus {
        guard isInstalledApplicationBundle(bundle) else {
            return .notRegistered
        }

        guard let appRequirement =
            CodeSigningRequirementReader.currentApplicationRequirement(
                bundle: bundle
            ),
            CaffeineIPC.exactCDHashes(in: appRequirement) != nil,
            let embeddedHelperRequirement =
                CodeSigningRequirementReader.embeddedHelperRequirement(
                    bundle: bundle
                ),
            CaffeineIPC.exactCDHashes(
                in: embeddedHelperRequirement
            ) != nil else {
            return .notFound
        }

        let daemonExists = fileManager.fileExists(
            atPath: caffeineInstalledDaemonURL.path
        )
        let helperExists = fileManager.fileExists(
            atPath: caffeineInstalledHelperURL.path
        )
        guard daemonExists || helperExists else {
            return .notRegistered
        }
        guard daemonExists, helperExists else {
            return .notFound
        }
        guard isSecureRootOwnedFile(
            caffeineInstalledDaemonURL,
            permissions: 0o644
        ), isSecureRootOwnedFile(
            caffeineInstalledHelperURL,
            permissions: 0o755
        ) else {
            logger.error(
                "The installed helper files have unsafe ownership or permissions"
            )
            return .notFound
        }

        guard let installedAppRequirement =
            installedApplicationRequirement(),
            CaffeineIPC.exactCDHashRequirementsMatch(
                appRequirement,
                installedAppRequirement
            ),
            let installedHelperRequirement =
                CodeSigningRequirementReader.designatedRequirement(
                    forCodeAt: caffeineInstalledHelperURL
                ),
            CaffeineIPC.exactCDHashRequirementsMatch(
                embeddedHelperRequirement,
                installedHelperRequirement
            ) else {
            logger.error(
                "The installed helper does not match this Caffeine build"
            )
            return .notRegistered
        }

        let registrationStatus = mapServiceStatus(
            SMAppService.statusForLegacyPlist(
                at: caffeineInstalledDaemonURL
            )
        )
        guard registrationStatus == .enabled else {
            // In particular, retain `.requiresApproval`: probing an unapproved
            // job must not turn the user's pending decision into a repair
            // request.
            return registrationStatus
        }

        switch await launchdInspector.health(
            label: CaffeineIPC.helperIdentifier,
            expectedPlistURL: caffeineInstalledDaemonURL,
            expectedProgramURL: caffeineInstalledHelperURL
        ) {
        case .running:
            return .enabled
        case .notLoaded, .notRunning:
            logger.error(
                """
                Service Management reports the helper enabled, but its \
                expected launchd job is not running yet
                """
            )
            // launchd can need a moment to start the enabled legacy job after
            // installation or login. This is transient unavailability, not
            // evidence that the root-installed payload is absent.
            return .unknown
        case .unexpectedConfiguration:
            logger.fault(
                """
                A launchd job with Caffeine's helper label uses unexpected \
                paths
                """
            )
            return .notFound
        }
    }

    func ensureRegistered() async -> HelperReadiness {
        guard isInstalledApplicationBundle(bundle) else {
            return .moveToApplications
        }
        guard let appRequirement =
            CodeSigningRequirementReader.currentApplicationRequirement(
                bundle: bundle
            ),
            CaffeineIPC.exactCDHashes(in: appRequirement) != nil,
            let helperRequirement =
                CodeSigningRequirementReader.embeddedHelperRequirement(
                    bundle: bundle
                ),
            CaffeineIPC.exactCDHashes(in: helperRequirement) != nil else {
            return .missing
        }

        switch await status() {
        case .enabled:
            return .ready
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .requiresInstallation
        case .unknown:
            return .unavailable
        }
    }

    private func installedApplicationRequirement() -> String? {
        guard let data = try? Data(
            contentsOf: caffeineInstalledDaemonURL
        ),
        let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
        let dictionary = plist as? [String: Any],
        let environment =
            dictionary["EnvironmentVariables"] as? [String: Any] else {
            return nil
        }
        return environment["CAFFEINE_APP_REQUIREMENT"] as? String
    }

    private func isSecureRootOwnedFile(
        _ url: URL,
        permissions: Int
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ), attributes[.type] as? FileAttributeType == .typeRegular,
        (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
        (attributes[.groupOwnerAccountID] as? NSNumber)?.intValue == 0,
        (attributes[.posixPermissions] as? NSNumber)?.intValue
            == permissions else {
            return false
        }
        return true
    }
}

@MainActor
final class LaunchAtLoginManager: LaunchAtLoginManaging {
    private let service: SMAppService
    private let bundle: Bundle

    init(
        service: SMAppService = .mainApp,
        bundle: Bundle = .main
    ) {
        self.service = service
        self.bundle = bundle
    }

    func status() async -> ServiceStatus {
        mapServiceStatus(service.status)
    }

    func register() async throws {
        guard isInstalledApplicationBundle(bundle) else {
            throw ApplicationInstallationError.moveToApplications
        }
        guard service.status != .enabled else {
            return
        }

        do {
            try service.register()
        } catch {
            guard service.status == .enabled else {
                throw error
            }
        }
    }

    func unregister() async throws {
        guard service.status != .notRegistered else {
            return
        }

        do {
            try await service.unregister()
        } catch {
            guard service.status == .notRegistered else {
                throw error
            }
        }
    }
}

private func mapServiceStatus(
    _ status: SMAppService.Status
) -> ServiceStatus {
    switch status {
    case .notRegistered:
        return .notRegistered
    case .enabled:
        return .enabled
    case .requiresApproval:
        return .requiresApproval
    case .notFound:
        return .notFound
    @unknown default:
        return .unknown
    }
}
