import Foundation
import ATProtoKit

/// A mutable local model wrapping ATProtoKit's `FeedViewPostDefinition`.
/// Mutable state (likeCount, isLiked, isReposted) enables optimistic UI updates
/// without mutating ATProtoKit's Sendable value types directly.
struct PostItem: Identifiable, Hashable {
    let id: String   // == uri
    let uri: String
    let cid: String

    // Author
    let authorDID: String
    let authorHandle: String
    let authorDisplayName: String?
    let authorAvatarURL: URL?

    // Content
    let text: String
    /// Facets from the PostRecord — server-side annotations for mentions, links, hashtags.
    /// Used to compute displayText and for accurate rich-text link attribution.
    let facets: [AppBskyLexicon.RichText.Facet]
    let createdAt: Date
    let indexedAt: Date

    // Engagement (mutable for optimistic updates)
    var likeCount: Int
    var repostCount: Int
    var replyCount: Int
    var quoteCount: Int
    var isLiked: Bool
    var likeURI: String?
    var isReposted: Bool
    var repostURI: String?
    /// Local-only flag set when the user submits a quote post for this item this session.
    /// The API has no viewer.quotedURI equivalent, so we track it ourselves for immediate UI feedback.
    var isQuoted: Bool = false

    // Embeds
    let embed: AppBskyLexicon.Feed.PostViewDefinition.EmbedUnion?

    // Thread structure
    let replyParentURI: String?
    let replyRootURI: String?

    // Reason (e.g., repost by someone else)
    let reason: FeedReason?

    // MARK: - Reason
    enum FeedReason: Hashable {
        case repost(byDID: String, byHandle: String, byDisplayName: String?, indexedAt: Date)
    }

    // MARK: - Init from ATProtoKit
    init(feedPost: AppBskyLexicon.Feed.FeedViewPostDefinition) {
        let post = feedPost.post
        self.uri = post.uri
        self.id = post.uri
        self.cid = post.cid
        self.authorDID = post.author.actorDID
        self.authorHandle = post.author.actorHandle
        self.authorDisplayName = post.author.displayName
        self.authorAvatarURL = post.author.avatarImageURL

        self.indexedAt = post.indexedAt

        // Extract text and facets from the record. The record is an UnknownType wrapping a PostRecord.
        if let postRecord = post.record.getRecord(ofType: AppBskyLexicon.Feed.PostRecord.self) {
            self.text = postRecord.text
            self.facets = postRecord.facets ?? []
            self.createdAt = postRecord.createdAt
        } else {
            self.text = ""
            self.facets = []
            self.createdAt = post.indexedAt
        }

        // Engagement counts
        self.likeCount = post.likeCount ?? 0
        self.repostCount = post.repostCount ?? 0
        self.replyCount = post.replyCount ?? 0
        self.quoteCount = post.quoteCount ?? 0

        // Viewer state
        self.isLiked = post.viewer?.likeURI != nil
        self.likeURI = post.viewer?.likeURI
        self.isReposted = post.viewer?.repostURI != nil
        self.repostURI = post.viewer?.repostURI

        // Embed
        self.embed = post.embed

        // Reply references — parent/root are typed union enums, not plain PostViewDefinition
        if let reply = feedPost.reply {
            if case .postView(let parentPost) = reply.parent {
                self.replyParentURI = parentPost.uri
            } else {
                self.replyParentURI = nil
            }
            if case .postView(let rootPost) = reply.root {
                self.replyRootURI = rootPost.uri
            } else {
                self.replyRootURI = nil
            }
        } else {
            self.replyParentURI = nil
            self.replyRootURI = nil
        }

        // Reason
        if let reason = feedPost.reason,
           case .reasonRepost(let repost) = reason {
            self.reason = .repost(
                byDID: repost.by.actorDID,
                byHandle: repost.by.actorHandle,
                byDisplayName: repost.by.displayName,
                indexedAt: repost.indexedAt
            )
        } else {
            self.reason = nil
        }
    }

    // MARK: - Init from PostViewDefinition (used by ThreadView)
    init(postView: AppBskyLexicon.Feed.PostViewDefinition) {
        let post = postView
        self.uri = post.uri
        self.id = post.uri
        self.cid = post.cid
        self.authorDID = post.author.actorDID
        self.authorHandle = post.author.actorHandle
        self.authorDisplayName = post.author.displayName
        self.authorAvatarURL = post.author.avatarImageURL

        self.indexedAt = post.indexedAt

        if let postRecord = post.record.getRecord(ofType: AppBskyLexicon.Feed.PostRecord.self) {
            self.text = postRecord.text
            self.facets = postRecord.facets ?? []
            self.createdAt = postRecord.createdAt
        } else {
            self.text = ""
            self.facets = []
            self.createdAt = post.indexedAt
        }

        self.likeCount = post.likeCount ?? 0
        self.repostCount = post.repostCount ?? 0
        self.replyCount = post.replyCount ?? 0
        self.quoteCount = post.quoteCount ?? 0

        self.isLiked = post.viewer?.likeURI != nil
        self.likeURI = post.viewer?.likeURI
        self.isReposted = post.viewer?.repostURI != nil
        self.repostURI = post.viewer?.repostURI

        self.embed = post.embed
        self.replyParentURI = nil
        self.replyRootURI = nil
        self.reason = nil
    }

    // MARK: - Init for optimistic/pending replies (ThreadView)
    /// Creates a lightweight placeholder PostItem for a reply that has been sent
    /// but not yet confirmed by the API. The URI is a local placeholder; it will
    /// be replaced when ThreadView reloads the thread after the round-trip completes.
    init(pendingURI: String, handle: String, text: String) {
        self.uri = pendingURI
        self.id = pendingURI
        self.cid = ""
        self.authorDID = ""
        self.authorHandle = handle
        self.authorDisplayName = nil
        self.authorAvatarURL = nil
        self.text = text
        self.facets = []
        let now = Date()
        self.createdAt = now
        self.indexedAt = now
        self.likeCount = 0
        self.repostCount = 0
        self.replyCount = 0
        self.quoteCount = 0
        self.isLiked = false
        self.likeURI = nil
        self.isReposted = false
        self.repostURI = nil
        self.isQuoted = false
        self.embed = nil
        self.replyParentURI = nil
        self.replyRootURI = nil
        self.reason = nil
    }

    // MARK: - Display Text
    /// The post text with any trailing embed URL stripped.
    ///
    /// Bluesky always appends the raw URL to the end of `text` when a post has an
    /// external link embed, and also annotates it as a link facet. Every client
    /// (official app, Ivory, Graysky…) hides this raw URL because the link card
    /// already renders it. We use the server-provided facets to find the exact byte
    /// range of the URL and trim it from the displayed string.
    ///
    /// The stripping only happens when:
    ///   • the embed is an `.embedExternalView` (a link card), AND
    ///   • a link facet whose URI matches the embed URI sits at the very end of the text
    ///
    /// All other posts return `text` unchanged.
    var displayText: String {
        // Only strip when there is an external link card embed
        guard case .embedExternalView(let external) = embed else { return text }
        let embedURI = external.external.uri

        // Find a link facet that (a) matches the embed URI and (b) ends at the very
        // end of the UTF-8 byte string — i.e. it's the trailing URL.
        let utf8 = text.utf8
        let totalBytes = utf8.count

        for facet in facets {
            for feature in facet.features {
                guard case .link(let link) = feature,
                      link.uri == embedURI,
                      facet.index.byteEnd == totalBytes
                else { continue }

                // Slice the text up to the start of this link facet's byte range,
                // then strip any trailing whitespace/newlines left behind.
                let startByte = facet.index.byteStart
                guard startByte >= 0, startByte <= totalBytes else { continue }
                let endIndex = utf8.index(utf8.startIndex, offsetBy: startByte)
                let trimmed = String(utf8[..<endIndex])?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? text
                return trimmed
            }
        }

        return text
    }

    // MARK: - Shareable URL
    /// Converts the AT URI (`at://did/app.bsky.feed.post/rkey`) into the
    /// canonical Bluesky web URL (`https://bsky.app/profile/{handle}/post/{rkey}`).
    /// This URL is used for the share sheet and opens correctly in browsers,
    /// iMessage link previews, and other apps.
    var bskyWebURL: URL? {
        // AT URI structure: at://<authority>/<collection>/<rkey>
        // We only need the rkey (last path segment).
        guard let rkey = uri.split(separator: "/").last.map(String.init),
              !rkey.isEmpty else { return nil }
        return URL(string: "https://bsky.app/profile/\(authorHandle)/post/\(rkey)")
    }

    // MARK: - Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PostItem, rhs: PostItem) -> Bool {
        lhs.id == rhs.id
    }
}
