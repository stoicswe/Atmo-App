import Foundation
import ATProtoKit
import Observation

// MARK: - Thread Reply Item

/// A reply in a flattened thread: the post plus where it sits in the tree.
/// Replies arrive depth-first, so a node's subtree is the contiguous run of
/// items after it with a greater depth.
public struct ThreadReplyItem: Identifiable, Sendable {
    public var id: String { post.id }
    public var post: PostItem
    /// 0 for direct replies to the root, +1 per generation below.
    public let depth: Int
    /// URI of the direct parent reply; nil for depth-0 nodes.
    public let parentID: String?
    /// True when at least one child follows in the flattened list.
    public var hasChildren: Bool

    public init(post: PostItem, depth: Int, parentID: String?, hasChildren: Bool = false) {
        self.post = post
        self.depth = depth
        self.parentID = parentID
        self.hasChildren = hasChildren
    }
}

// MARK: - Reply Sort

/// Orderings for a thread's top-level replies. Sorting reorders depth-0
/// nodes only; each root's subtree follows it unchanged.
public enum ThreadReplySort: String, CaseIterable, Sendable {
    /// Chronological, as delivered by the API.
    case time
    /// Depth-0 replies by like count, descending.
    case hot
}

// MARK: - ThreadViewModel

/// Loads a post's full thread (root + all replies, flattened depth-first)
/// — the model behind the Apple `ThreadView` and the Linux thread page.
///
/// Like/repost toggling is not duplicated here: seed a `TimelineViewModel`
/// with `allPosts` and route interactions through it, the way the Apple
/// app does.
@Observable
@MainActor
public final class ThreadViewModel {

    /// The thread's root post (not the tapped post when that was a reply).
    public private(set) var rootPost: PostItem?
    /// Every reply below the root, depth-first.
    public private(set) var replies: [ThreadReplyItem] = []
    /// Non-nil when the opened post was itself a reply — UIs highlight it.
    public private(set) var focusedPostURI: String?
    public private(set) var isLoading = false
    public private(set) var error: Error?

    /// The post the user opened (any post in the thread).
    public let postURI: String

    private let service: ATProtoService

    public init(service: ATProtoService, postURI: String) {
        self.service = service
        self.postURI = postURI
    }

    /// Root first, then replies in display order — ready for
    /// `TimelineViewModel.seedPosts` so like/repost lookups succeed.
    public var allPosts: [PostItem] {
        (rootPost.map { [$0] } ?? []) + replies.map(\.post)
    }

    /// The replies under the requested ordering.
    public func sortedReplies(_ sort: ThreadReplySort) -> [ThreadReplyItem] {
        sort == .hot ? ThreadAssembly.hotOrder(replies) : replies
    }

    /// Fetches the thread. When the opened post is itself a reply, walks up
    /// to the root and fetches the root's thread, so the whole conversation
    /// renders with the opened post highlighted (`focusedPostURI`).
    public func load() async {
        guard let kit = service.atProtoKit else { return }
        isLoading = replies.isEmpty  // spinner on cold load only, like the Apple view
        error = nil
        do {
            let initial = try await kit.getPostThread(from: postURI)
            guard case .threadViewPost(let initialThread) = initial.thread else {
                isLoading = false
                return
            }

            let rootURI = Self.findRootURI(from: initialThread)
            let rootThread: AppBskyLexicon.Feed.ThreadViewPostDefinition
            if rootURI == postURI {
                rootThread = initialThread
            } else {
                let rootOutput = try await kit.getPostThread(from: rootURI)
                guard case .threadViewPost(let thread) = rootOutput.thread else {
                    isLoading = false
                    return
                }
                rootThread = thread
            }

            rootPost = PostItem(postView: rootThread.post)
            focusedPostURI = (postURI == rootURI) ? nil : postURI
            replies = ThreadAssembly.flatten(
                rootThread.replies ?? [],
                post: { node -> PostItem? in
                    guard case .threadViewPost(let thread) = node else { return nil }
                    return PostItem(postView: thread.post)
                },
                children: { node in
                    guard case .threadViewPost(let thread) = node else { return [] }
                    return thread.replies ?? []
                }
            )
        } catch {
            self.error = error
        }
        isLoading = false
    }

    /// Walks `parent` links to the top of the thread.
    private static func findRootURI(
        from thread: AppBskyLexicon.Feed.ThreadViewPostDefinition
    ) -> String {
        var current = thread
        while let parentUnion = current.parent,
              case .threadViewPost(let parentThread) = parentUnion {
            current = parentThread
        }
        return current.post.uri
    }
}

// MARK: - Thread Assembly

/// Pure thread-shaping logic, generic over the node type so tests drive it
/// with plain fixtures instead of ATProtoKit lexicon values.
enum ThreadAssembly {

    /// Depth-first flatten of a reply forest. A node whose `post` resolves
    /// to nil (blocked/deleted/not-found unions) is skipped along with its
    /// entire subtree — matching the API's own visibility rules.
    static func flatten<Node>(
        _ nodes: [Node],
        post: (Node) -> PostItem?,
        children: (Node) -> [Node]
    ) -> [ThreadReplyItem] {
        var collected: [ThreadReplyItem] = []
        collect(nodes, depth: 0, parentID: nil, post: post, children: children, into: &collected)
        for index in collected.indices {
            let id = collected[index].id
            collected[index].hasChildren = collected.contains { $0.parentID == id }
        }
        return collected
    }

    private static func collect<Node>(
        _ nodes: [Node],
        depth: Int,
        parentID: String?,
        post: (Node) -> PostItem?,
        children: (Node) -> [Node],
        into collected: inout [ThreadReplyItem]
    ) {
        for node in nodes {
            guard let item = post(node) else { continue }
            collected.append(ThreadReplyItem(post: item, depth: depth, parentID: parentID))
            collect(
                children(node),
                depth: depth + 1,
                parentID: item.id,
                post: post,
                children: children,
                into: &collected
            )
        }
    }

    /// Reorders depth-0 replies by like count (descending, stable); each
    /// root's subtree stays attached behind it.
    static func hotOrder(_ replies: [ThreadReplyItem]) -> [ThreadReplyItem] {
        var blocks: [(root: ThreadReplyItem, subtree: [ThreadReplyItem])] = []
        var index = 0
        while index < replies.count {
            let node = replies[index]
            guard node.depth == 0 else { index += 1; continue }
            var subtree: [ThreadReplyItem] = []
            var next = index + 1
            while next < replies.count, replies[next].depth > 0 {
                subtree.append(replies[next])
                next += 1
            }
            blocks.append((root: node, subtree: subtree))
            index = next
        }
        let sorted = blocks.enumerated().sorted { lhs, rhs in
            if lhs.element.root.post.likeCount != rhs.element.root.post.likeCount {
                return lhs.element.root.post.likeCount > rhs.element.root.post.likeCount
            }
            return lhs.offset < rhs.offset
        }
        return sorted.flatMap { [$0.element.root] + $0.element.subtree }
    }
}
