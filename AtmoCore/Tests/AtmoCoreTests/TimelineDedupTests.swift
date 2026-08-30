import Testing
@testable import AtmoCore

@MainActor
struct TimelineDedupTests {

    @Test func suppressesParentImmediatelyBeforeItsReply() {
        let parent = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        let reply = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/2",
            replyParentURI: parent.uri
        )
        let result = TimelineViewModel.deduplicateThreadContext([parent, reply])
        #expect(result.map(\.uri) == [reply.uri])
    }

    @Test func keepsUnrelatedNeighbours() {
        let a = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        let b = PostItem(testURI: "at://did:b/app.bsky.feed.post/2")
        let result = TimelineViewModel.deduplicateThreadContext([a, b])
        #expect(result.count == 2)
    }

    @Test func collapsesAWholeChainDownToTheFinalReply() {
        // grandparent → parent → reply, adjacent in the feed: each cell is
        // followed by its direct reply, so only the final reply remains and
        // shows its ancestors as inline thread context.
        let grandparent = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        let parent = PostItem(
            testURI: "at://did:a/app.bsky.feed.post/2",
            replyParentURI: grandparent.uri
        )
        let reply = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/3",
            replyParentURI: parent.uri
        )
        let result = TimelineViewModel.deduplicateThreadContext([grandparent, parent, reply])
        #expect(result.map(\.uri) == [reply.uri])
    }

    @Test func doesNotSuppressAParentThatIsNotImmediatelyBeforeItsReply() {
        // A reply elsewhere in the feed doesn't suppress its parent when an
        // unrelated post sits between them.
        let parent = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        let unrelated = PostItem(testURI: "at://did:c/app.bsky.feed.post/2")
        let reply = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/3",
            replyParentURI: parent.uri
        )
        let result = TimelineViewModel.deduplicateThreadContext([parent, unrelated, reply])
        #expect(result.map(\.uri) == [parent.uri, unrelated.uri, reply.uri])
    }

    @Test func emptyAndSingleInputsPassThrough() {
        #expect(TimelineViewModel.deduplicateThreadContext([]).isEmpty)
        let single = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        #expect(TimelineViewModel.deduplicateThreadContext([single]).count == 1)
    }
}
