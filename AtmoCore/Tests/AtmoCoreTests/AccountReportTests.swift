import Foundation
import Testing
@testable import AtmoCore

struct AccountReportTests {

    @Test func categoriesMatchOfficialAppOrder() {
        let titles = AccountReport.categories.map(\.title)
        #expect(titles == [
            "Misleading", "Adult content", "Harassment or hate", "Violence",
            "Child safety", "Self-harm or dangerous behaviors",
            "Breaking site rules", "Other"
        ])
    }

    @Test func everyCategoryHasOptionsWithUniqueReasons() {
        var seen = Set<String>()
        for category in AccountReport.categories {
            #expect(!category.options.isEmpty)
            for option in category.options {
                #expect(seen.insert(option.id).inserted, "duplicate reason \(option.id)")
            }
        }
    }

    @Test func otherReasonsAskForDetails() {
        for category in AccountReport.categories {
            let last = category.options.last!
            #expect(last.asksForDetails, "\(category.title)'s last option should be an 'Other' reason")
            for option in category.options.dropLast() {
                #expect(!option.asksForDetails)
            }
        }
    }

    @Test func childSafetyAndExtremismAreBlueskyOnly() {
        let csam = AccountReport.Option("x", .reasonChildSafetyCSAM)
        let extremist = AccountReport.Option("x", .reasonViolenceExtremistContent)
        let spam = AccountReport.Option("x", .reasonMisleadingSpam)
        #expect(csam.isBlueskyOnly)
        #expect(extremist.isBlueskyOnly)
        #expect(!spam.isBlueskyOnly)
    }

    @Test func ozoneReasonsEncodeAsFullNSIDs() {
        #expect(AccountReport.Option("x", .reasonMisleadingSpam).reason.rawValue
                == "tools.ozone.report.defs#reasonMisleadingSpam")
    }

    @Test func moderationServiceFallbackIsBluesky() {
        #expect(ModerationServiceInfo.bluesky.isBluesky)
        #expect(ModerationServiceInfo.bluesky.name == "Bluesky Moderation Service")
        let other = ModerationServiceInfo(did: "did:plc:x", handle: "labeler.test", displayName: nil, avatarURL: nil)
        #expect(!other.isBluesky)
        #expect(other.name == "@labeler.test")
    }
}
