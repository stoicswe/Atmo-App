import Foundation
import Testing
@testable import AtmoCore

@MainActor
struct TimelineDedupTests {

    /// Fixed base date so ordering in tests is deterministic.
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func suppressesParentImmediatelyBeforeItsReply() {
        let parent = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        let reply = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/2",
            replyParentURI: parent.uri,
            replyRootURI: parent.uri
        )
        let result = TimelineViewModel.collapseThreadSlices([parent, reply])
        #expect(result.map(\.uri) == [reply.uri])
    }

    @Test func keepsUnrelatedNeighbours() {
        let a = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        let b = PostItem(testURI: "at://did:b/app.bsky.feed.post/2")
        let result = TimelineViewModel.collapseThreadSlices([a, b])
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
        let result = TimelineViewModel.collapseThreadSlices([grandparent, parent, reply])
        #expect(result.map(\.uri) == [reply.uri])
    }

    @Test func collapsesScatteredSlicesOfOneThreadToTheNewestReply() {
        // The same conversation appearing as multiple non-adjacent feed
        // items collapses to a single cell — the newest reply — at the
        // highest position any slice occupied.
        let root = PostItem(
            testURI: "at://did:a/app.bsky.feed.post/1",
            indexedAt: t0
        )
        let unrelated = PostItem(
            testURI: "at://did:c/app.bsky.feed.post/2",
            indexedAt: t0.addingTimeInterval(30)
        )
        let reply = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/3",
            replyParentURI: root.uri,
            replyRootURI: root.uri,
            indexedAt: t0.addingTimeInterval(60)
        )
        let result = TimelineViewModel.collapseThreadSlices([root, unrelated, reply])
        #expect(result.map(\.uri) == [reply.uri, unrelated.uri])
    }

    @Test func keepsOnlyTheNewestOfSeveralRepliesInTheSameThread() {
        let rootURI = "at://did:a/app.bsky.feed.post/root"
        let older = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/1",
            replyParentURI: rootURI,
            replyRootURI: rootURI,
            indexedAt: t0
        )
        let between = PostItem(
            testURI: "at://did:c/app.bsky.feed.post/2",
            indexedAt: t0.addingTimeInterval(10)
        )
        let newer = PostItem(
            testURI: "at://did:d/app.bsky.feed.post/3",
            replyParentURI: older.uri,
            replyRootURI: rootURI,
            indexedAt: t0.addingTimeInterval(120)
        )
        // Feed order: newest first.
        let result = TimelineViewModel.collapseThreadSlices([newer, between, older])
        #expect(result.map(\.uri) == [newer.uri, between.uri])
    }

    @Test func repostsAreExemptFromThreadCollapse() {
        // A repost of a thread member keeps its own cell — "X reposted"
        // is a distinct story — and never absorbs the organic slice.
        let rootURI = "at://did:a/app.bsky.feed.post/root"
        let repost = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/1",
            replyParentURI: rootURI,
            replyRootURI: rootURI,
            indexedAt: t0.addingTimeInterval(60),
            isRepost: true
        )
        let organicReply = PostItem(
            testURI: "at://did:c/app.bsky.feed.post/2",
            replyParentURI: rootURI,
            replyRootURI: rootURI,
            indexedAt: t0
        )
        let result = TimelineViewModel.collapseThreadSlices([repost, organicReply])
        #expect(result.map(\.uri) == [repost.uri, organicReply.uri])
    }

    @Test func doesNotMergeDistinctThreads() {
        let replyA = PostItem(
            testURI: "at://did:a/app.bsky.feed.post/1",
            replyParentURI: "at://did:x/app.bsky.feed.post/rootA",
            replyRootURI: "at://did:x/app.bsky.feed.post/rootA",
            indexedAt: t0.addingTimeInterval(60)
        )
        let replyB = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/2",
            replyParentURI: "at://did:y/app.bsky.feed.post/rootB",
            replyRootURI: "at://did:y/app.bsky.feed.post/rootB",
            indexedAt: t0
        )
        let result = TimelineViewModel.collapseThreadSlices([replyA, replyB])
        #expect(result.count == 2)
    }

    @Test func emptyAndSingleInputsPassThrough() {
        #expect(TimelineViewModel.collapseThreadSlices([]).isEmpty)
        let single = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        #expect(TimelineViewModel.collapseThreadSlices([single]).count == 1)
    }
}
