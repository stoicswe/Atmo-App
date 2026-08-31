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

    @Test func neverEmitsDuplicateURIs() {
        // A repost carries the ORIGINAL post's URI. When someone reposts a
        // reply AND that same reply is its thread's newest member, the
        // repost row and the thread representative used to share one
        // identity — which crashes SwiftUI's lazy ForEach.
        let rootURI = "at://did:a/app.bsky.feed.post/root"
        let replyURI = "at://did:b/app.bsky.feed.post/reply"
        let repostOfReply = PostItem(
            testURI: replyURI,
            replyParentURI: rootURI,
            replyRootURI: rootURI,
            indexedAt: t0.addingTimeInterval(120),
            isRepost: true
        )
        let between = PostItem(
            testURI: "at://did:c/app.bsky.feed.post/other",
            indexedAt: t0.addingTimeInterval(60)
        )
        let organicReply = PostItem(
            testURI: replyURI,
            replyParentURI: rootURI,
            replyRootURI: rootURI,
            indexedAt: t0
        )
        let result = TimelineViewModel.collapseThreadSlices(
            [repostOfReply, between, organicReply]
        )
        let uris = result.map(\.uri)
        #expect(Set(uris).count == uris.count)
    }

    @Test func duplicateRepostsCollapseToOne() {
        let uri = "at://did:a/app.bsky.feed.post/1"
        let repostA = PostItem(testURI: uri, indexedAt: t0, isRepost: true)
        let repostB = PostItem(testURI: uri, indexedAt: t0.addingTimeInterval(30), isRepost: true)
        let result = TimelineViewModel.collapseThreadSlices([repostA, repostB])
        #expect(result.count == 1)
    }

    @Test func emptyAndSingleInputsPassThrough() {
        #expect(TimelineViewModel.collapseThreadSlices([]).isEmpty)
        let single = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        #expect(TimelineViewModel.collapseThreadSlices([single]).count == 1)
    }

    // MARK: - Chronological ordering

    @Test func cellsComeOutNewestFirstRegardlessOfInputOrder() {
        // A stale-slice merge can hand collapse an out-of-order array:
        // a 34-minute-old reply cell sitting above a 7-minute-old post.
        let root = "at://did:a/app.bsky.feed.post/root"
        let reply = PostItem(
            testURI: "at://did:a/app.bsky.feed.post/reply",
            replyParentURI: root,
            replyRootURI: root,
            indexedAt: t0.addingTimeInterval(-34 * 60)
        )
        let fresh = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/fresh",
            indexedAt: t0.addingTimeInterval(-7 * 60)
        )
        let result = TimelineViewModel.collapseThreadSlices([reply, fresh])
        #expect(result.map(\.uri) == [fresh.uri, reply.uri])
    }

    @Test func staleSliceOfKnownConversationDoesNotHoistItsCell() {
        // The head fetch re-delivers the 10h-old ROOT of a conversation
        // whose newest reply is 34m old; prepended above a 7m post, the
        // conversation must still sort below the 7m post.
        let rootURI = "at://did:a/app.bsky.feed.post/root"
        let staleRoot = PostItem(testURI: rootURI, indexedAt: t0.addingTimeInterval(-10 * 3600))
        let fresh = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/fresh",
            indexedAt: t0.addingTimeInterval(-7 * 60)
        )
        let replyCell = PostItem(
            testURI: "at://did:a/app.bsky.feed.post/reply",
            replyParentURI: rootURI,
            replyRootURI: rootURI,
            indexedAt: t0.addingTimeInterval(-34 * 60)
        )
        // Merge seam order: [stale slice][existing cells...]
        let result = TimelineViewModel.collapseThreadSlices([staleRoot, fresh, replyCell])
        #expect(result.map(\.uri) == [fresh.uri, replyCell.uri])
    }

    @Test func repostsSortByRepostTimeNotOriginalPostTime() {
        let repost = PostItem(
            testURI: "at://did:a/app.bsky.feed.post/old",
            indexedAt: t0.addingTimeInterval(-60),
            isRepost: true
        )
        let older = PostItem(
            testURI: "at://did:b/app.bsky.feed.post/mid",
            indexedAt: t0.addingTimeInterval(-120)
        )
        let newest = PostItem(
            testURI: "at://did:c/app.bsky.feed.post/new",
            indexedAt: t0
        )
        let result = TimelineViewModel.collapseThreadSlices([older, repost, newest])
        #expect(result.map(\.uri) == [newest.uri, repost.uri, older.uri])
    }
}
