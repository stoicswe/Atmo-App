import Testing
@testable import AtmoCore

/// Covers the composer's interaction-gate semantics: which combinations
/// require threadgate/postgate records and what "nobody" means.
struct PostInteractionSettingsTests {

    @Test func defaultsNeedNoGates() {
        let s = PostInteractionSettings()
        #expect(s.isDefault)
        #expect(!s.needsThreadgate)
        #expect(!s.nobodyCanReply)
    }

    @Test func disablingQuotesIsNotDefaultButNeedsNoThreadgate() {
        var s = PostInteractionSettings()
        s.allowQuotePosts = false
        #expect(!s.isDefault)
        #expect(!s.needsThreadgate)
    }

    @Test func nobodyIsAGateWithNoRules() {
        var s = PostInteractionSettings()
        s.anyoneCanReply = false
        #expect(s.needsThreadgate)
        #expect(s.nobodyCanReply)
    }

    @Test func anyRuleClearsNobody() {
        var s = PostInteractionSettings()
        s.anyoneCanReply = false
        s.followersCanReply = true
        #expect(s.needsThreadgate)
        #expect(!s.nobodyCanReply)
    }
}
