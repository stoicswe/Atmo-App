import Foundation
import Testing
@testable import AtmoCore

/// The session-wide reveal memory behind the content veils: a post or
/// media item revealed in one view stays revealed in every other view of
/// the same content until re-covered.
@MainActor
struct ContentRevealStoreTests {

    @Test func revealCarriesAcrossViewsAndReCoverClears() {
        let store = ContentRevealStore()
        let post = "at://did:plc:abc/app.bsky.feed.post/1"
        #expect(!store.isRevealed(post))

        store.setRevealed(post, true)
        #expect(store.isRevealed(post))
        // A second "view" of the same post asks the same store.
        #expect(store.isRevealed("at://did:plc:abc/app.bsky.feed.post/1"))

        store.setRevealed(post, false)
        #expect(!store.isRevealed(post))
    }

    @Test func keysAreIndependent() {
        let store = ContentRevealStore()
        store.setRevealed("post-a", true)
        #expect(!store.isRevealed("post-b"))
        #expect(!store.isRevealed("https://cdn/img.jpg"))

        store.setRevealed("https://cdn/img.jpg", true)
        store.reset()
        #expect(!store.isRevealed("post-a"))
        #expect(!store.isRevealed("https://cdn/img.jpg"))
    }

    @Test func repeatedRevealIsIdempotent() {
        let store = ContentRevealStore()
        store.setRevealed("k", true)
        store.setRevealed("k", true)
        #expect(store.revealed.count == 1)
        store.setRevealed("missing", false)
        #expect(store.revealed == ["k"])
    }
}
