import Foundation
import Security

enum CodeSigningRequirementReader {
    static func designatedRequirement(
        forCodeAt url: URL
    ) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            return nil
        }

        return designatedRequirement(for: staticCode)
    }

    static func currentApplicationRequirement(
        bundle: Bundle = .main
    ) -> String? {
        guard let staticCode = currentApplicationCode(bundle: bundle) else {
            return nil
        }
        return designatedRequirement(for: staticCode)
    }

    static func validatesApplicationCopy(
        at url: URL,
        exactRequirement: String
    ) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            exactRequirement as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return false
        }

        let validationFlagBits =
            kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: validationFlagBits),
            requirement
        ) == errSecSuccess
    }

    static func embeddedHelperRequirement(
        bundle: Bundle = .main
    ) -> String? {
        designatedRequirement(
            forCodeAt: bundle.bundleURL.appendingPathComponent(
                "Contents/MacOS/CaffeineHelper",
                isDirectory: false
            )
        )
    }

    private static func currentApplicationCode(
        bundle: Bundle
    ) -> SecStaticCode? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
              let dynamicCode else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            dynamicCode,
            SecCSFlags(rawValue: kSecCSUseAllArchitectures),
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            return nil
        }

        var codeURL: CFURL?
        guard SecCodeCopyPath(
            staticCode,
            [],
            &codeURL
        ) == errSecSuccess,
        let codeURL else {
            return nil
        }

        let signedPath = (codeURL as URL)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let bundlePath = bundle.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard signedPath == bundlePath else {
            return nil
        }
        return staticCode
    }

    private static func designatedRequirement(
        for staticCode: SecStaticCode
    ) -> String? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            staticCode,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return nil
        }

        var requirementText: CFString?
        guard SecRequirementCopyString(
            requirement,
            [],
            &requirementText
        ) == errSecSuccess,
        let requirementText else {
            return nil
        }

        return requirementText as String
    }
}
