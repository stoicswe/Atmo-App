import Foundation
import Testing
import ATProtoKit
@testable import AtmoCore

/// Covers the saved-feeds merge (drawer's pinned/unpinned split).
struct CustomFeedsTests {

    @Test func mergeSplitsByPinAndPreservesOrder() {
        let refs = [
            SavedFeedsStore.SavedFeedRef(uri: "at://f/1", isPinned: true),
            SavedFeedsStore.SavedFeedRef(uri: "at://f/2", isPinned: false),
            SavedFeedsStore.SavedFeedRef(uri: "at://f/3", isPinned: true),
        ]
        let names = ["at://f/1": "Discover", "at://f/2": "Science", "at://f/3": "Art"]
        let result = SavedFeedsStore.merge(refs: refs, names: names, avatars: [:])
        #expect(result.pinned.map(\.displayName) == ["Discover", "Art"])
        #expect(result.unpinned.map(\.displayName) == ["Science"])
    }

    @Test func unresolvedGeneratorsAreDropped() {
        let refs = [
            SavedFeedsStore.SavedFeedRef(uri: "at://f/gone", isPinned: true),
            SavedFeedsStore.SavedFeedRef(uri: "at://f/here", isPinned: true),
        ]
        let result = SavedFeedsStore.merge(refs: refs, names: ["at://f/here": "Alive"], avatars: [:])
        #expect(result.pinned.map(\.uri) == ["at://f/here"])
    }
}


/// Saved-feed writes: the pure list transforms behind subscribe,
/// unsubscribe, and pin, as applied to the account's `savedFeedsPrefV2`.
struct SavedFeedWriteTests {
    private typealias SavedFeed = AppBskyLexicon.Actor.SavedFeed

    private func item(_ uri: String, pinned: Bool) -> SavedFeed {
        SavedFeed(feedID: "id-\(uri)", feedType: .feed, value: uri, isPinned: pinned)
    }

    @Test func subscribeAppendsOnceAndUpdatesPin() {
        let base = [item("at://f/a", pinned: true)]
        let added = SavedFeedsStore.subscribing(base, uri: "at://f/b", pinned: false)
        #expect(added.map(\.value) == ["at://f/a", "at://f/b"])
        #expect(added.last?.isPinned == false)
        #expect(added.last?.feedType == .feed)
        #expect(!(added.last?.feedID.isEmpty ?? true))

        // Already saved: no duplicate, pin follows the request.
        let again = SavedFeedsStore.subscribing(added, uri: "at://f/b", pinned: true)
        #expect(again.count == 2)
        #expect(again.last?.isPinned == true)
        #expect(again.last?.feedID == added.last?.feedID)
    }

    @Test func unsubscribeAndPinToggle() {
        let base = [item("at://f/a", pinned: true), item("at://f/b", pinned: false)]
        #expect(SavedFeedsStore.unsubscribing(base, uri: "at://f/a").map(\.value) == ["at://f/b"])
        #expect(SavedFeedsStore.unsubscribing(base, uri: "at://f/zzz").count == 2)
        let pinned = SavedFeedsStore.settingPinned(base, uri: "at://f/b", pinned: true)
        #expect(pinned[1].isPinned)
        #expect(pinned[0].isPinned)
        #expect(pinned[1].feedID == "id-at://f/b")
    }
}
