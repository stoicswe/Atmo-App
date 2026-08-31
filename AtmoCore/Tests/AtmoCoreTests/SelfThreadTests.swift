import Foundation
import Testing
@testable import AtmoCore

/// Covers author self-thread detection: the chain builder the Reader view
/// uses, and the `selfThreadCount` that drives the feed's "k/n" pills.
struct SelfThreadTests {

    private let author = "did:plc:author"
    private let other = "did:plc:other"

    private func post(
        _ name: String,
        by did: String,
        replyTo parent: String? = nil,
        root: String? = nil,
        at seconds: TimeInterval = 0
    ) -> PostItem {
        PostItem(
            testURI: "at://\(did)/app.bsky.feed.post/\(name)",
            authorDID: did,
            replyParentURI: parent,
            replyRootURI: root,
            indexedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func uri(_ name: String, by did: String) -> String {
        "at://\(did)/app.bsky.feed.post/\(name)"
    }

    // MARK: - Chain building

    @Test func chainFollowsConsecutiveSelfReplies() {
        let root = post("1", by: author)
        let rootURI = uri("1", by: author)
        let replies = [
            post("2", by: author, replyTo: rootURI, root: rootURI, at: 10),
            post("3", by: author, replyTo: uri("2", by: author), root: rootURI, at: 20),
            // Interleaved reply from someone else must not break or join the chain.
            post("x", by: other, replyTo: rootURI, root: rootURI, at: 5),
        ]
        let chain = SelfThread.chain(root: root, replies: replies)
        #expect(chain.map(\.uri) == [rootURI, uri("2", by: author), uri("3", by: author)])
    }

    @Test func chainIsJustTheRootWhenAuthorNeverSelfReplied() {
        let root = post("1", by: author)
        let replies = [post("x", by: other, replyTo: uri("1", by: author), at: 5)]
        #expect(SelfThread.chain(root: root, replies: replies).map(\.uri) == [uri("1", by: author)])
    }

    @Test func earliestSelfReplyWinsWhenAuthorForked() {
        let root = post("1", by: author)
        let rootURI = uri("1", by: author)
        let replies = [
            post("late", by: author, replyTo: rootURI, root: rootURI, at: 50),
            post("early", by: author, replyTo: rootURI, root: rootURI, at: 10),
        ]
        let chain = SelfThread.chain(root: root, replies: replies)
        #expect(chain.map(\.uri) == [rootURI, uri("early", by: author)])
    }

    @Test func authorReplyDeeperInSomeoneElsesBranchDoesNotExtendChain() {
        let root = post("1", by: author)
        let rootURI = uri("1", by: author)
        let replies = [
            post("x", by: other, replyTo: rootURI, root: rootURI, at: 5),
            // The author replying to someone else's reply is a conversation,
            // not a continuation of their own thread.
            post("2", by: author, replyTo: uri("x", by: other), root: rootURI, at: 10),
        ]
        #expect(SelfThread.chain(root: root, replies: replies).count == 1)
    }

    @Test func malformedCycleTerminates() {
        // root ← a ← b, plus a rogue duplicate of `a` claiming to reply to
        // `b` — following it would revisit `a` forever without the guard.
        let root = post("1", by: author)
        let rootURI = uri("1", by: author)
        let a = post("a", by: author, replyTo: rootURI, root: rootURI, at: 10)
        let b = post("b", by: author, replyTo: uri("a", by: author), root: rootURI, at: 20)
        let rogue = post("a", by: author, replyTo: uri("b", by: author), root: rootURI, at: 30)
        let chain = SelfThread.chain(root: root, replies: [a, b, rogue])
        #expect(chain.map(\.uri) == [rootURI, uri("a", by: author), uri("b", by: author)])
    }

    // MARK: - Feed pill count

    private func cell(ancestorsBy dids: [String], selfBy did: String, connected: Bool = true) -> PostItem {
        var ancestors: [PostItem] = []
        var previousURI: String? = nil
        for (i, aDid) in dids.enumerated() {
            let p = post("a\(i)", by: aDid, replyTo: previousURI, at: TimeInterval(i))
            ancestors.append(p)
            previousURI = uri("a\(i)", by: aDid)
        }
        var main = post(
            "main",
            by: did,
            replyTo: connected ? previousURI : "at://did:plc:elsewhere/app.bsky.feed.post/gone",
            at: 100
        )
        main.threadAncestors = ancestors
        return main
    }

    @Test func fullSelfChainYieldsCount() {
        let main = cell(ancestorsBy: [author, author], selfBy: author)
        #expect(main.selfThreadCount == 3)
    }

    @Test func twoPostChainCounts() {
        let main = cell(ancestorsBy: [author], selfBy: author)
        #expect(main.selfThreadCount == 2)
    }

    @Test func mixedAuthorsIsNotASelfThread() {
        let main = cell(ancestorsBy: [author, other], selfBy: author)
        #expect(main.selfThreadCount == nil)
    }

    @Test func detachedParentIsNotASelfThread() {
        let main = cell(ancestorsBy: [author, author], selfBy: author, connected: false)
        #expect(main.selfThreadCount == nil)
    }

    @Test func gappedAncestorsAreNotASelfThread() {
        // Ancestors [root, parent] where parent does NOT reply to root.
        let root = post("r", by: author)
        let parent = post("p", by: author, replyTo: "at://did:plc:author/app.bsky.feed.post/missing", at: 1)
        var main = post("m", by: author, replyTo: uri("p", by: author), at: 2)
        main.threadAncestors = [root, parent]
        #expect(main.selfThreadCount == nil)
    }

    @Test func plainPostHasNoCount() {
        #expect(post("solo", by: author).selfThreadCount == nil)
    }
}
