import Foundation

/// Author self-threads: a root post followed by the author's own unbroken
/// chain of replies, each replying directly to the previous link. Powers the
/// "k/n" pills in the feed and the thread Reader view.
public enum SelfThread {

    /// Builds the author's unbroken self-reply chain starting at `root`:
    /// the root plus consecutive replies authored by the root's author, each
    /// a direct reply to the previous link. Replies may arrive in any order.
    /// When the author replied to the same link more than once, the earliest
    /// reply continues the chain.
    public static func chain(root: PostItem, replies: [PostItem]) -> [PostItem] {
        var chain = [root]
        // Guards against malformed reply graphs (a cycle would loop forever).
        var seen: Set<String> = [root.uri]
        var currentURI = root.uri
        while true {
            let next = replies
                .filter {
                    $0.authorDID == root.authorDID
                        && $0.replyParentURI == currentURI
                        && !seen.contains($0.uri)
                }
                .min { $0.indexedAt < $1.indexedAt }
            guard let next else { break }
            chain.append(next)
            seen.insert(next.uri)
            currentURI = next.uri
        }
        return chain
    }
}

extension PostItem {
    /// When this post closes an unbroken same-author chain in its feed cell
    /// (root → … → this post: every shown ancestor is by this author, with
    /// no gap and no missing parent), the total number of posts in that
    /// visible chain (ancestors + self); nil otherwise. The feed cell shows
    /// ancestor `i` (oldest first) as post `i + 1` of the count, and this
    /// post as the last.
    public var selfThreadCount: Int? {
        guard isSelfThreadSlice,
              !threadContextHasGap,
              !threadContextIsDetached
        else { return nil }
        return threadAncestors.count + 1
    }

    /// True when every post shown in this cell (ancestors + self) is by the
    /// same author — an author self-thread slice, even when generations are
    /// missing (gap/detached). Only connected slices also report
    /// `selfThreadCount`; a gapped slice can't be numbered truthfully from
    /// the feed payload, so UIs show an unnumbered thread marker instead.
    public var isSelfThreadSlice: Bool {
        !threadAncestors.isEmpty
            && threadAncestors.allSatisfy { $0.authorDID == authorDID }
    }
}
