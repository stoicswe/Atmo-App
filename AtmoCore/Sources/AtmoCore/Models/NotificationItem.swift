import Foundation
import ATProtoKit

public struct NotificationItem: Identifiable, Hashable, Sendable {
    public let id: String  // == uri
    public let uri: String
    public let cid: String

    public let authorDID: String
    public let authorHandle: String
    public let authorDisplayName: String?
    public let authorAvatarURL: URL?

    public let reason: NotificationReason
    public let isRead: Bool
    public let indexedAt: Date

    // Optionally associated post
    public let associatedPostURI: String?

    /// A short piece of the content behind the notification: for replies,
    /// mentions, and quotes this is the other person's own text (carried
    /// in the notification record); for likes and reposts it is the text
    /// of the USER'S post that was liked/reposted, resolved separately
    /// (`resolveSubjectSnippets`) because like/repost records carry no
    /// text of their own. Follows have none.
    public internal(set) var contentSnippet: String?

    public enum NotificationReason: String, Sendable {
        case like
        case repost
        case follow
        case mention
        case reply
        case quote
        // Newer Bluesky reasons — previously all fell into `.unknown` and
        // rendered as a generic "interacted with you".
        case subscribedPost = "subscribed-post"
        case likeViaRepost = "like-via-repost"
        case repostViaRepost = "repost-via-repost"
        case starterpackJoined = "starterpack-joined"
        case verified
        case unverified
        case unknown

        public var displayText: String {
            switch self {
            case .like:              return "liked your post"
            case .repost:            return "reposted your post"
            case .follow:            return "followed you"
            case .mention:           return "mentioned you"
            case .reply:             return "replied to your post"
            case .quote:             return "quoted your post"
            case .subscribedPost:    return "shared a new post"
            case .likeViaRepost:     return "liked your repost"
            case .repostViaRepost:   return "reposted your repost"
            case .starterpackJoined: return "joined via your starter pack"
            case .verified:          return "verified you"
            case .unverified:        return "removed your verification"
            case .unknown:           return "interacted with you"
            }
        }

        public var icon: String {
            switch self {
            case .like:              return "heart.fill"
            case .repost:            return "arrow.2.squarepath"
            case .follow:            return "person.badge.plus.fill"
            case .mention:           return "at"
            case .reply:             return "bubble.left.fill"
            case .quote:             return "quote.bubble.fill"
            case .subscribedPost:    return "bell.badge.fill"
            case .likeViaRepost:     return "heart.fill"
            case .repostViaRepost:   return "arrow.2.squarepath"
            case .starterpackJoined: return "person.2.fill"
            case .verified:          return "checkmark.seal.fill"
            case .unverified:        return "xmark.seal"
            case .unknown:           return "bell.fill"
            }
        }

        /// The settings toggle governing this reason's push alerts:
        /// via-repost variants follow their base kind, so "Likes" covers
        /// likes on reposts too.
        public var settingsKind: NotificationReason {
            switch self {
            case .likeViaRepost:   return .like
            case .repostViaRepost: return .repost
            default:               return self
            }
        }

        /// The snippet for these reasons is the text of the SUBJECT post
        /// (the user's post/repost that was acted on), resolved through a
        /// batched `getPosts` lookup.
        var snippetComesFromSubjectPost: Bool {
            switch self {
            case .like, .repost, .likeViaRepost, .repostViaRepost: return true
            default: return false
            }
        }
    }

    public init(notification: AppBskyLexicon.Notification.Notification) {
        self.uri = notification.uri
        self.id = notification.uri
        self.cid = notification.cid
        self.authorDID = notification.author.actorDID
        self.authorHandle = notification.author.actorHandle
        self.authorDisplayName = notification.author.displayName
        self.authorAvatarURL = notification.author.avatarImageURL
        self.reason = NotificationReason(rawValue: notification.reason.rawValue) ?? .unknown
        self.isRead = notification.isRead
        self.indexedAt = notification.indexedAt
        self.associatedPostURI = notification.reasonSubjectURI
        // Replies, mentions, quotes, and subscribed-account posts ARE
        // posts — their text rides along in the notification record
        // itself.
        switch self.reason {
        case .reply, .mention, .quote, .subscribedPost:
            self.contentSnippet = notification.record
                .getRecord(ofType: AppBskyLexicon.Feed.PostRecord.self)?.text
        default:
            self.contentSnippet = nil
        }
    }

    /// Internal test fixture initializer.
    init(
        testURI: String,
        reason: NotificationReason,
        authorHandle: String = "test.bsky.social",
        associatedPostURI: String? = nil,
        contentSnippet: String? = nil,
        isRead: Bool = false,
        indexedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.uri = testURI
        self.id = testURI
        self.cid = "cid-\(testURI)"
        self.authorDID = "did:test:\(authorHandle)"
        self.authorHandle = authorHandle
        self.authorDisplayName = nil
        self.authorAvatarURL = nil
        self.reason = reason
        self.isRead = isRead
        self.indexedAt = indexedAt
        self.associatedPostURI = associatedPostURI
        self.contentSnippet = contentSnippet
    }

    // Equality is synthesized memberwise — deliberately. Snippets are
    // injected AFTER the list first renders; an identity-only `==` would
    // make the updated item compare equal to the old one and SwiftUI
    // would skip re-rendering the row (the same trap that froze the
    // profile Follow button).

    // MARK: - Snippet resolution helpers (pure, unit-tested)

    /// The subject-post URIs that still need their text fetched: likes
    /// and reposts (direct or via-repost) whose snippet is unresolved.
    /// Deduplicated, in first-appearance order.
    public static func unresolvedSubjectURIs(in items: [NotificationItem]) -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard item.contentSnippet == nil,
                  item.reason.snippetComesFromSubjectPost,
                  let uri = item.associatedPostURI,
                  seen.insert(uri).inserted else { return nil }
            return uri
        }
    }

    /// Returns the items with fetched subject-post texts filled into the
    /// like/repost entries that were missing one. Items that already have
    /// a snippet (replies, mentions, quotes) are untouched.
    public static func injectingSnippets(
        into items: [NotificationItem],
        texts: [String: String]
    ) -> [NotificationItem] {
        items.map { item in
            guard item.contentSnippet == nil,
                  item.reason.snippetComesFromSubjectPost,
                  let uri = item.associatedPostURI,
                  let text = texts[uri],
                  !text.isEmpty else { return item }
            var updated = item
            updated.contentSnippet = text
            return updated
        }
    }

    /// The authors whose subscribed-post rows still lack text — the
    /// notification record should carry the post, so this is the fallback
    /// path: fetch that account's latest post and use its content.
    /// Deduplicated, in first-appearance order.
    public static func subscribedAuthorsNeedingLatestPost(in items: [NotificationItem]) -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard item.contentSnippet == nil,
                  item.reason == .subscribedPost,
                  seen.insert(item.authorDID).inserted else { return nil }
            return item.authorDID
        }
    }

    /// Fills fetched latest-post texts into subscribed-post rows that
    /// were missing one, keyed by author DID.
    public static func injectingLatestPosts(
        into items: [NotificationItem],
        textsByAuthor: [String: String]
    ) -> [NotificationItem] {
        items.map { item in
            guard item.contentSnippet == nil,
                  item.reason == .subscribedPost,
                  let text = textsByAuthor[item.authorDID],
                  !text.isEmpty else { return item }
            var updated = item
            updated.contentSnippet = text
            return updated
        }
    }
}
