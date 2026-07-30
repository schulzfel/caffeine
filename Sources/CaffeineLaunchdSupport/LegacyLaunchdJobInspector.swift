import Foundation

/// The read-only health of an installed legacy LaunchDaemon.
public enum LegacyLaunchdJobHealth: Equatable, Sendable {
    /// launchd has the expected job loaded and its process is running.
    case running

    /// No job with the expected label is loaded in the system domain.
    case notLoaded

    /// The expected job is loaded but its process is not running.
    case notRunning

    /// A job owns the label but does not point at the expected fixed paths.
    case unexpectedConfiguration
}

/// Inspects a legacy LaunchDaemon without mutating its registration or
/// approval state.
public struct LegacyLaunchdJobInspector: Sendable {
    public init() {}

    public func health(
        label: String,
        expectedPlistURL: URL,
        expectedProgramURL: URL
    ) async -> LegacyLaunchdJobHealth {
        let expectedPlistPath = expectedPlistURL.path
        let expectedProgramPath = expectedProgramURL.path

        return await Task.detached(priority: .utility) {
            Self.inspectSynchronously(
                label: label,
                expectedPlistPath: expectedPlistPath,
                expectedProgramPath: expectedProgramPath
            )
        }.value
    }

    /// Classifies `launchctl print` output. This stays public so the strict
    /// fixed-path parsing can be covered without loading a real system job.
    public static func classify(
        launchctlOutput: String,
        expectedPlistPath: String,
        expectedProgramPath: String
    ) -> LegacyLaunchdJobHealth {
        guard field(named: "path", in: launchctlOutput)
                == expectedPlistPath,
              field(named: "program", in: launchctlOutput)
                == expectedProgramPath else {
            return .unexpectedConfiguration
        }

        return field(named: "state", in: launchctlOutput) == "running"
            ? .running
            : .notRunning
    }

    private static func inspectSynchronously(
        label: String,
        expectedPlistPath: String,
        expectedProgramPath: String
    ) -> LegacyLaunchdJobHealth {
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .notLoaded
        }

        let outputData =
            standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0,
              let output = String(data: outputData, encoding: .utf8) else {
            return .notLoaded
        }

        return classify(
            launchctlOutput: output,
            expectedPlistPath: expectedPlistPath,
            expectedProgramPath: expectedProgramPath
        )
    }

    private static func field(
        named name: String,
        in output: String
    ) -> String? {
        let prefix = "\(name) = "
        for rawLine in output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else {
                continue
            }
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }
}
