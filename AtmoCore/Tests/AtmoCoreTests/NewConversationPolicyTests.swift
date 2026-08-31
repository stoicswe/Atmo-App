import Testing
@testable import AtmoCore

/// Covers the DM-reachability rule used by the new-conversation picker.
struct NewConversationPolicyTests {

    @Test func allowAllIsAlwaysReachable() {
        #expect(NewConversationViewModel.canReceiveDMs(allowIncoming: "all", theyFollowMe: false))
        #expect(NewConversationViewModel.canReceiveDMs(allowIncoming: "all", theyFollowMe: true))
    }

    @Test func allowNoneIsNeverReachable() {
        #expect(!NewConversationViewModel.canReceiveDMs(allowIncoming: "none", theyFollowMe: true))
    }

    @Test func allowFollowingRequiresTheirFollow() {
        #expect(NewConversationViewModel.canReceiveDMs(allowIncoming: "following", theyFollowMe: true))
        #expect(!NewConversationViewModel.canReceiveDMs(allowIncoming: "following", theyFollowMe: false))
    }

    @Test func missingDeclarationDefaultsToFollowing() {
        #expect(NewConversationViewModel.canReceiveDMs(allowIncoming: nil, theyFollowMe: true))
        #expect(!NewConversationViewModel.canReceiveDMs(allowIncoming: nil, theyFollowMe: false))
    }
}
