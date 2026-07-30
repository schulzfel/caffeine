import Testing
@testable import CaffeineIPC

@Suite("Caffeine IPC")
struct CaffeineIPCTests {
    @Test
    func customerRequirementPinsIdentifierAnchorAndTeam() {
        let requirement = CaffeineIPC.developerIDCodeSigningRequirement(
            identifier: "tech.example.helper",
            teamIdentifier: "ABC123DE45"
        )

        #expect(requirement?.contains(#"identifier "tech.example.helper""#) == true)
        #expect(requirement?.contains("anchor apple generic") == true)
        #expect(
            requirement?.contains(
                #"certificate leaf[subject.OU] = "ABC123DE45""#
            ) == true
        )
    }

    @Test(
        "Invalid Team IDs do not produce a trusted requirement",
        arguments: [
            nil,
            "SHORT",
            "abc123de45",
            "ABC123DE4-",
        ] as [String?]
    )
    func invalidTeamIdentifierIsRejected(
        teamIdentifier: String?
    ) {
        #expect(
            CaffeineIPC.developerIDCodeSigningRequirement(
                identifier: "tech.example.helper",
                teamIdentifier: teamIdentifier
            ) == nil
        )
    }

    @Test
    func exactAdHocRequirementAcceptsUniversalHashes() {
        let first = String(repeating: "a", count: 40)
        let second = String(repeating: "B", count: 40)
        let requirement =
            #"cdhash H"\#(first)" or cdhash H"\#(second)""#

        #expect(
            CaffeineIPC.exactCDHashes(in: requirement) == [
                first,
                second.lowercased(),
            ]
        )
    }

    @Test
    func exactRequirementsCompareIndependentOfCaseAndOrder() {
        let first = String(repeating: "1", count: 40)
        let second = String(repeating: "a", count: 40)

        #expect(
            CaffeineIPC.exactCDHashRequirementsMatch(
                #"cdhash H"\#(first)" or cdhash H"\#(second)""#,
                #"cdhash H"\#(second.uppercased())" or cdhash H"\#(first)""#
            )
        )
    }

    @Test(
        "Unsafe or malformed exact requirements are rejected",
        arguments: [
            #"identifier "tech.46h.caffeine""#,
            #"cdhash H"1234""#,
            #"cdhash H"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and true"#,
            "",
        ]
    )
    func invalidExactRequirementIsRejected(_ requirement: String) {
        #expect(CaffeineIPC.exactCDHashes(in: requirement) == nil)
    }
}
