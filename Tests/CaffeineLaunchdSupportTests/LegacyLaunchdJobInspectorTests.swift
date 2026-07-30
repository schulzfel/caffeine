import Foundation
import Testing
@testable import CaffeineLaunchdSupport

@Suite("Legacy launchd job inspector")
struct LegacyLaunchdJobInspectorTests {
    private let plistPath =
        "/Library/LaunchDaemons/tech.46h.caffeine.helper.plist"
    private let programPath =
        "/Library/PrivilegedHelperTools/tech.46h.caffeine.helper"

    @Test
    func expectedRunningJobIsHealthy() {
        let output = """
        system/tech.46h.caffeine.helper = {
            path = \(plistPath)
            state = running
            program = \(programPath)
        }
        """

        #expect(classify(output) == .running)
    }

    @Test
    func expectedJobThatIsNotRunningIsUnhealthy() {
        let output = """
        system/tech.46h.caffeine.helper = {
            path = \(plistPath)
            state = exited
            program = \(programPath)
        }
        """

        #expect(classify(output) == .notRunning)
    }

    @Test
    func jobWithUnexpectedProgramIsRejected() {
        let output = """
        system/tech.46h.caffeine.helper = {
            path = \(plistPath)
            state = running
            program = /tmp/tech.46h.caffeine.helper
        }
        """

        #expect(classify(output) == .unexpectedConfiguration)
    }

    @Test
    func jobWithUnexpectedPlistIsRejected() {
        let output = """
        system/tech.46h.caffeine.helper = {
            path = /tmp/tech.46h.caffeine.helper.plist
            state = running
            program = \(programPath)
        }
        """

        #expect(classify(output) == .unexpectedConfiguration)
    }

    @Test
    func absentSystemJobIsReportedAsNotLoaded() async {
        let uniqueLabel =
            "tech.46h.caffeine.tests.\(UUID().uuidString)"
        let result = await LegacyLaunchdJobInspector().health(
            label: uniqueLabel,
            expectedPlistURL: URL(fileURLWithPath: plistPath),
            expectedProgramURL: URL(fileURLWithPath: programPath)
        )

        #expect(result == .notLoaded)
    }

    private func classify(_ output: String) -> LegacyLaunchdJobHealth {
        LegacyLaunchdJobInspector.classify(
            launchctlOutput: output,
            expectedPlistPath: plistPath,
            expectedProgramPath: programPath
        )
    }
}
