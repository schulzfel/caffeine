import CaffeineIPC
import Darwin
import Foundation

/// A verified helper package whose descriptor remains open for its lifetime.
///
/// Keeping this value alive prevents an ordinary detach of the private,
/// read-only image until Installer has accepted the package URL.
@MainActor
final class PreparedHelperInstaller {
    let url: URL

    private let lease: FileHandle

    init(url: URL, lease: FileHandle) {
        self.url = url
        self.lease = lease
    }
}

/// Prepares the helper package without trusting a writable external copy.
///
/// The package is a resource sealed by the exact running app signature. The
/// complete bundle is staged into a private, unpredictable disk image and that
/// image is mounted read-only. The mounted copy is then validated against the
/// running process's exact Universal CDHash requirement. Installer is only
/// given the package on that kernel-enforced read-only volume.
///
/// The retained package descriptor blocks ordinary unmounts during handoff.
/// A process deliberately using a forced unmount is outside this unsigned
/// Installer handoff's threat model.
@MainActor
struct HelperInstallerLocator {
    private static let stagingPrefix =
        "tech.46h.caffeine-helper-installer-"
    private static let installerName =
        "Install Caffeine Helper.pkg"
    private static let imageName = "Caffeine Helper Installer.dmg"
    private static let mountName = "mounted"
    private static let sourceName = "source"

    private let bundle: Bundle
    private let fileManager: FileManager

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
    }

    func matchingInstaller() -> PreparedHelperInstaller? {
        cleanupStalePreparedCopies()

        guard let runningAppRequirement =
            CodeSigningRequirementReader.currentApplicationRequirement(
                bundle: bundle
            ),
            CaffeineIPC.exactCDHashes(
                in: runningAppRequirement
            )?.count == 2 else {
            return nil
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                Self.stagingPrefix + UUID().uuidString,
                isDirectory: true
            )
        let sourceDirectory = stagingRoot.appendingPathComponent(
            Self.sourceName,
            isDirectory: true
        )
        let sourceApp = sourceDirectory.appendingPathComponent(
            bundle.bundleURL.lastPathComponent,
            isDirectory: true
        )
        let imageURL = stagingRoot.appendingPathComponent(
            Self.imageName,
            isDirectory: false
        )
        let mountURL = stagingRoot.appendingPathComponent(
            Self.mountName,
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(
                at: bundle.bundleURL,
                to: sourceApp
            )
            try fileManager.createDirectory(
                at: mountURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            removePreparedImage(root: stagingRoot)
            return nil
        }

        guard runDiskImageTool([
            "create",
            "-quiet",
            "-fs", "HFS+",
            "-format", "UDZO",
            "-volname", "Caffeine Helper",
            "-srcfolder", sourceDirectory.path,
            imageURL.path,
        ]),
        isRegularNonSymbolicFile(imageURL) else {
            removePreparedImage(root: stagingRoot)
            return nil
        }
        try? fileManager.removeItem(at: sourceDirectory)

        guard runDiskImageTool([
            "attach",
            "-quiet",
            "-readonly",
            "-nobrowse",
            "-noautoopen",
            "-mountpoint", mountURL.path,
            imageURL.path,
        ]) else {
            removePreparedImage(root: stagingRoot)
            return nil
        }

        do {
            // DiskImages retains its open image object. Removing the directory
            // entry prevents another process with this UID from reopening and
            // rewriting the backing bytes after validation.
            try fileManager.removeItem(at: imageURL)
        } catch {
            _ = detachPreparedImage(at: mountURL)
            removePreparedImage(root: stagingRoot)
            return nil
        }

        let mountedApp = mountURL.appendingPathComponent(
            bundle.bundleURL.lastPathComponent,
            isDirectory: true
        )
        let installerURL = mountedApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(Self.installerName)
        guard let volumeIdentity = readOnlyVolumeIdentity(mountURL),
              isNonSymbolicDirectory(mountURL),
              isRegularNonSymbolicFile(installerURL),
              CodeSigningRequirementReader.validatesApplicationCopy(
                at: mountedApp,
                exactRequirement: runningAppRequirement
              ),
              lockPreparedRoot(stagingRoot),
              hasPreparedRootPermissions(stagingRoot),
              !fileManager.fileExists(atPath: imageURL.path),
              readOnlyVolumeIdentity(mountURL) == volumeIdentity,
              let installerLease = try? FileHandle(
                forReadingFrom: installerURL
              ),
              CodeSigningRequirementReader.validatesApplicationCopy(
                at: mountedApp,
                exactRequirement: runningAppRequirement
              ),
              readOnlyVolumeIdentity(mountURL) == volumeIdentity else {
            _ = detachPreparedImage(at: mountURL)
            removePreparedImage(root: stagingRoot)
            return nil
        }

        // Holding the package open keeps ordinary detach attempts from
        // succeeding during the LaunchServices handoff to Installer.
        return PreparedHelperInstaller(
            url: installerURL,
            lease: installerLease
        )
    }

    private func lockPreparedRoot(_ root: URL) -> Bool {
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: root.path
            )
            return true
        } catch {
            return false
        }
    }

    private func hasPreparedRootPermissions(_ root: URL) -> Bool {
        let expectedOwner = NSNumber(value: getuid())
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: root.path
        ),
        attributes[.ownerAccountID] as? NSNumber == expectedOwner,
        attributes[.posixPermissions] as? NSNumber
            == NSNumber(value: 0o500) else {
            return false
        }
        return true
    }

    private func cleanupStalePreparedCopies(
        now: Date = Date()
    ) {
        let temporaryDirectory = fileManager.temporaryDirectory
        let keys: [URLResourceKey] = [
            .creationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let oldestPermittedDate = now.addingTimeInterval(-24 * 60 * 60)
        for candidate in candidates {
            guard isPreparedDirectoryName(candidate.lastPathComponent),
                  let values = try? candidate.resourceValues(
                    forKeys: Set(keys)
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let creationDate = values.creationDate,
                  creationDate <= oldestPermittedDate else {
                continue
            }
            let mount = candidate.appendingPathComponent(
                Self.mountName,
                isDirectory: true
            )
            if !fileManager.fileExists(atPath: mount.path) {
                removePreparedImage(root: candidate)
                continue
            }
            guard isNonSymbolicDirectory(mount) else {
                continue
            }
            guard let isMountedVolume = isVolumeRoot(mount) else {
                continue
            }
            if isMountedVolume {
                guard readOnlyVolumeIdentity(mount) != nil,
                      detachPreparedImage(at: mount) else {
                    continue
                }
            }
            removePreparedImage(root: candidate)
        }
    }

    private func isPreparedDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix(Self.stagingPrefix) else {
            return false
        }
        let suffix = String(name.dropFirst(Self.stagingPrefix.count))
        return UUID(uuidString: suffix)?.uuidString == suffix
    }

    private func removePreparedImage(root: URL) {
        guard isPreparedDirectoryName(root.lastPathComponent),
              let rootValues = try? root.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            return
        }

        let source = root.appendingPathComponent(
            Self.sourceName,
            isDirectory: true
        )
        let mount = root.appendingPathComponent(
            Self.mountName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: mount.path) {
            guard isNonSymbolicDirectory(mount),
                  isVolumeRoot(mount) == false else {
                return
            }
        }
        for directory in [root, source, mount] {
            guard let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ),
            values.isDirectory == true,
            values.isSymbolicLink != true else {
                continue
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        try? fileManager.removeItem(at: root)
    }

    private func detachPreparedImage(at mountURL: URL) -> Bool {
        runDiskImageTool([
            "detach",
            "-quiet",
            mountURL.path,
        ])
    }

    private func runDiskImageTool(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/hdiutil",
            isDirectory: false
        )
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func readOnlyVolumeIdentity(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(
            forKeys: [
                .volumeIsReadOnlyKey,
                .volumeUUIDStringKey,
            ]
        ) else {
            return nil
        }
        guard values.volumeIsReadOnly == true,
              let identifier = values.volumeUUIDString,
              !identifier.isEmpty else {
            return nil
        }
        return identifier
    }

    private func isNonSymbolicDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true
            && values.isSymbolicLink != true
    }

    private func isVolumeRoot(_ url: URL) -> Bool? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeURLKey]
        ),
        let volumeURL = values.volume else {
            return nil
        }
        return volumeURL.resolvingSymlinksInPath().standardizedFileURL
            == url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isRegularNonSymbolicFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

}
