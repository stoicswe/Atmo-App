import Foundation
import Testing
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
