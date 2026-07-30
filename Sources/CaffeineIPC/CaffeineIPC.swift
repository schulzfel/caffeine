import Foundation

/// Names shared by the menu-bar app and its privileged helper.
public enum CaffeineIPC {
    public static let applicationIdentifier = "tech.46h.caffeine"
    public static let helperIdentifier = "tech.46h.caffeine.helper"
    public static let helperMachServiceName = helperIdentifier

    /// Builds the Developer ID peer requirement used by an identity-signed
    /// build. There is deliberately no identifier-only fallback: ad-hoc
    /// identifiers are chosen by the signer and are not an authorization
    /// boundary.
    public static func developerIDCodeSigningRequirement(
        identifier: String,
        teamIdentifier: String?
    ) -> String? {
        guard let teamIdentifier,
              isValidTeamIdentifier(teamIdentifier) else {
            return nil
        }

        return """
        identifier "\(identifier)" and \
        anchor apple generic and \
        certificate leaf[subject.OU] = "\(teamIdentifier)"
        """
    }

    /// Extracts the architecture-specific hashes from an exact ad-hoc
    /// designated requirement such as:
    ///
    /// `cdhash H"…" or cdhash H"…"`
    ///
    /// The returned hashes are normalized and sorted so the app can compare
    /// the requirement generated during installation with its running code.
    public static func exactCDHashes(
        in requirement: String
    ) -> [String]? {
        let fullPattern = #"""
        ^\s*cdhash\s+H"[0-9A-Fa-f]{40}"(?:\s+or\s+cdhash\s+H"[0-9A-Fa-f]{40}")*\s*$
        """#
        guard requirement.range(
            of: fullPattern,
            options: .regularExpression
        ) != nil else {
            return nil
        }

        let hashPattern = #"[0-9A-Fa-f]{40}"#
        guard let expression = try? NSRegularExpression(
            pattern: hashPattern
        ) else {
            return nil
        }
        let matches = expression.matches(
            in: requirement,
            range: NSRange(
                requirement.startIndex..<requirement.endIndex,
                in: requirement
            )
        )
        guard !matches.isEmpty else {
            return nil
        }
        return matches.compactMap {
            Range($0.range, in: requirement).map {
                requirement[$0].lowercased()
            }
        }.sorted()
    }

    public static func exactCDHashRequirementsMatch(
        _ first: String,
        _ second: String
    ) -> Bool {
        guard let firstHashes = exactCDHashes(in: first),
              let secondHashes = exactCDHashes(in: second) else {
            return false
        }
        return firstHashes == secondHashes
    }

    public static func isValidTeamIdentifier(_ value: String) -> Bool {
        guard value.utf8.count == 10 else {
            return false
        }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
        }
    }
}

/// The complete surface exposed by the privileged helper.
///
/// Keep this protocol deliberately small: every method here becomes callable
/// across a root boundary after the peer's code signature has been validated.
@objc public protocol CaffeineHelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Bool) -> Void)
}
