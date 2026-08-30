import Foundation
import Testing
@testable import AtmoCore

/// Covers the thread-context helpers feed UIs use to place "more in thread"
/// breaks between the embedded ancestors of a reply.
struct ThreadContextTests {

    private let rootURI = "at://did:a/app.bsky.feed.post/root"
    private let parentURI = "at://did:b/app.bsky.feed.post/parent"

    private func reply(ancestors: [PostItem], parentURI: String?) -> PostItem {
        var post = PostItem(
            testURI: "at://did:c/app.bsky.feed.post/reply",
            replyParentURI: parentURI,
            replyRootURI: rootURI
        )
        post.threadAncestors = ancestors
        return post
    }

    @Test func noContextMeansNoGapAndNoDetachment() {
        let post = reply(ancestors: [], parentURI: parentURI)
        #expect(!post.threadContextHasGap)
        #expect(!post.threadContextIsDetached)
    }

    @Test func directParentChainIsSeamless() {
        // root ← parent ← reply, fully connected.
        let root = PostItem(testURI: rootURI)
        let parent = PostItem(
            testURI: parentURI,
            replyParentURI: rootURI,
            replyRootURI: rootURI
        )
        let post = reply(ancestors: [root, parent], parentURI: parentURI)
        #expect(!post.threadContextHasGap)
        #expect(!post.threadContextIsDetached)
    }

    @Test func skippedGenerationsBetweenRootAndParentAreAGap() {
        // parent replies to some post that is NOT the root → break between them.
        let root = PostItem(testURI: rootURI)
        let parent = PostItem(
            testURI: parentURI,
            replyParentURI: "at://did:x/app.bsky.feed.post/middle",
            replyRootURI: rootURI
        )
        let post = reply(ancestors: [root, parent], parentURI: parentURI)
        #expect(post.threadContextHasGap)
        #expect(!post.threadContextIsDetached)
    }

    @Test func missingDirectParentDetachesThePost() {
        // Parent deleted/blocked: only the root arrives — break above the post.
        let root = PostItem(testURI: rootURI)
        let post = reply(ancestors: [root], parentURI: parentURI)
        #expect(!post.threadContextHasGap)
        #expect(post.threadContextIsDetached)
    }

    @Test func directReplyToRootShowsSingleSeamlessAncestor()  {
        // parent == root collapses to one embedded ancestor.
        let root = PostItem(testURI: rootURI)
        let post = reply(ancestors: [root], parentURI: rootURI)
        #expect(!post.threadContextHasGap)
        #expect(!post.threadContextIsDetached)
    }
}
