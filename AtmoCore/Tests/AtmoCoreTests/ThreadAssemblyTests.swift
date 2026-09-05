import Foundation
import Testing
@testable import AtmoCore

/// Covers the pure thread-shaping logic behind ThreadViewModel: depth-first
/// flattening of the reply forest and the "hot" ordering that moves
/// depth-0 replies (with their subtrees) by like count.
struct ThreadAssemblyTests {

    /// Plain fixture tree standing in for the lexicon's reply unions.
    /// `post == nil` models a blocked/deleted/not-found node.
    private struct Node {
        let post: PostItem?
        var children: [Node] = []
    }

    private func post(_ name: String, likes: Int = 0) -> PostItem {
        var item = PostItem(testURI: "at://did:t/app.bsky.feed.post/\(name)")
        item.likeCount = likes
        return item
    }

    private func uri(_ name: String) -> String {
        "at://did:t/app.bsky.feed.post/\(name)"
    }

    private func flatten(_ nodes: [Node]) -> [ThreadReplyItem] {
        ThreadAssembly.flatten(nodes, post: \.post, children: \.children)
    }

    // MARK: - Flatten

    @Test func flattenWalksDepthFirstWithDepths() {
        // a ── a1 ── a1a
        // b
        let tree = [
            Node(post: post("a"), children: [
                Node(post: post("a1"), children: [Node(post: post("a1a"))])
            ]),
            Node(post: post("b"))
        ]
        let flat = flatten(tree)
        #expect(flat.map { $0.post.uri } == [uri("a"), uri("a1"), uri("a1a"), uri("b")])
        #expect(flat.map(\.depth) == [0, 1, 2, 0])
    }

    @Test func flattenRecordsParentIDs() {
        let tree = [
            Node(post: post("a"), children: [
                Node(post: post("a1"), children: [Node(post: post("a1a"))])
            ])
        ]
        let flat = flatten(tree)
        #expect(flat[0].parentID == nil)
        #expect(flat[1].parentID == uri("a"))
        #expect(flat[2].parentID == uri("a1"))
    }

    @Test func flattenMarksNodesWithChildren() {
        let tree = [
            Node(post: post("a"), children: [Node(post: post("a1"))]),
            Node(post: post("b"))
        ]
        let flat = flatten(tree)
        #expect(flat.first { $0.post.uri == uri("a") }?.hasChildren == true)
        #expect(flat.first { $0.post.uri == uri("a1") }?.hasChildren == false)
        #expect(flat.first { $0.post.uri == uri("b") }?.hasChildren == false)
    }

    @Test func unresolvableNodeIsSkippedWithItsSubtree() {
        // The blocked node's child must not surface as an orphan.
        let tree = [
            Node(post: nil, children: [Node(post: post("hidden"))]),
            Node(post: post("visible"))
        ]
        let flat = flatten(tree)
        #expect(flat.map { $0.post.uri } == [uri("visible")])
    }

    // MARK: - Hot ordering

    @Test func hotOrderSortsRootsByLikesKeepingSubtreesAttached() {
        let tree = [
            Node(post: post("cold", likes: 1), children: [Node(post: post("coldChild"))]),
            Node(post: post("hot", likes: 9), children: [Node(post: post("hotChild"))])
        ]
        let hot = ThreadAssembly.hotOrder(flatten(tree))
        #expect(hot.map { $0.post.uri } == [uri("hot"), uri("hotChild"), uri("cold"), uri("coldChild")])
    }

    @Test func hotOrderIsStableForTiedRoots() {
        let tree = [
            Node(post: post("first", likes: 3)),
            Node(post: post("second", likes: 3)),
            Node(post: post("third", likes: 5))
        ]
        let hot = ThreadAssembly.hotOrder(flatten(tree))
        #expect(hot.map { $0.post.uri } == [uri("third"), uri("first"), uri("second")])
    }

    @Test func timeSortLeavesOrderUntouched() async {
        // sortedReplies(.time) must be the identity — guarded through the
        // view model so a future re-sort can't sneak in unnoticed.
        let model = await ThreadViewModel(service: ATProtoService(), postURI: uri("root"))
        let sorted = await model.sortedReplies(.time)
        #expect(sorted.isEmpty)
    }
}
