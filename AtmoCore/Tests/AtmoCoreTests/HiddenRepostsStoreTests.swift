import Foundation
import Testing
@testable import AtmoCore

@MainActor
struct HiddenRepostsStoreTests {

    private func makeStore(suite: String = "atmo-hidden-reposts-\(UUID().uuidString)") -> (HiddenRepostsStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        return (HiddenRepostsStore(defaults: defaults), defaults)
    }

    @Test func defaultsToNothingHidden() {
        let (store, _) = makeStore()
        #expect(store.hiddenDIDs.isEmpty)
        #expect(!store.isHidingReposts(from: "did:plc:a"))
    }

    @Test func togglePersistsAcrossInstances() {
        let suite = "atmo-hidden-reposts-\(UUID().uuidString)"
        let (store, defaults) = makeStore(suite: suite)
        store.setHidingReposts(true, from: "did:plc:a")
        #expect(store.isHidingReposts(from: "did:plc:a"))

        let reloaded = HiddenRepostsStore(defaults: defaults)
        #expect(reloaded.isHidingReposts(from: "did:plc:a"))

        reloaded.setHidingReposts(false, from: "did:plc:a")
        #expect(!reloaded.isHidingReposts(from: "did:plc:a"))
        #expect(HiddenRepostsStore(defaults: defaults).hiddenDIDs.isEmpty)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func onlyRepostsByHiddenAccountsAreDropped() {
        let hidden: Set<String> = ["did:plc:hidden"]
        let repostByHidden = PostItem.FeedReason.repost(
            byDID: "did:plc:hidden", byHandle: "h", byDisplayName: nil, indexedAt: Date())
        let repostByOther = PostItem.FeedReason.repost(
            byDID: "did:plc:other", byHandle: "o", byDisplayName: nil, indexedAt: Date())
        #expect(HiddenRepostsStore.isHiddenRepost(reason: repostByHidden, hiddenDIDs: hidden))
        #expect(!HiddenRepostsStore.isHiddenRepost(reason: repostByOther, hiddenDIDs: hidden))
        // The hidden account's own (non-repost) posts are unaffected.
        #expect(!HiddenRepostsStore.isHiddenRepost(reason: nil, hiddenDIDs: hidden))
    }
}
