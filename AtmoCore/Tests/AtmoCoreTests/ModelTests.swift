import Foundation
import Testing
@testable import AtmoCore

struct ModelTests {

    @Test func bskyWebURLIsBuiltFromHandleAndRecordKey() {
        let post = PostItem(
            testURI: "at://did:plc:abc/app.bsky.feed.post/3kxyz",
            authorHandle: "alice.bsky.social"
        )
        #expect(post.bskyWebURL?.absoluteString == "https://bsky.app/profile/alice.bsky.social/post/3kxyz")
    }

    @Test func pendingReplyPlaceholderCarriesTextAndHandle() {
        let post = PostItem(pendingURI: "pending://1", handle: "alice.test", text: "hi")
        #expect(post.id == "pending://1")
        #expect(post.authorHandle == "alice.test")
        #expect(post.text == "hi")
        #expect(!post.isLiked && !post.isReposted)
    }

    @Test func bookmarkedPostSnapshotsThePost() {
        let post = PostItem(
            testURI: "at://did:plc:abc/app.bsky.feed.post/1",
            authorHandle: "alice.test",
            text: "bookmark me"
        )
        let bookmark = BookmarkedPost(post: post)
        #expect(bookmark.id == post.uri)
        #expect(bookmark.text == "bookmark me")
        #expect(bookmark.authorHandle == "alice.test")
    }

    @Test func composerDraftEmptinessIgnoresWhitespace() {
        let empty = ComposerDraft(posts: [DraftPost(text: "  \n ")])
        #expect(empty.isEmpty)
        let full = ComposerDraft(posts: [DraftPost(text: "  \n "), DraftPost(text: "words")])
        #expect(!full.isEmpty)
    }

    @Test func dateFormattingBuckets() {
        #expect(Date.now.atmoFormatted() == "now")
        #expect(Date.now.addingTimeInterval(-5 * 60).atmoFormatted() == "5m")
        #expect(Date.now.addingTimeInterval(-3 * 3600).atmoFormatted() == "3h")
        #expect(Date.now.addingTimeInterval(-2 * 86400).atmoFormatted() == "2d")
    }
}
