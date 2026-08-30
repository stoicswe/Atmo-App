import Foundation

// MARK: - Per-user post subscriptions
/// How the user wants to hear about another account's posts (set from
/// that account's profile page).
public enum UserPostNotificationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// No notifications from this account.
    case off
    /// Every new post, including the account's reposts.
    case allPosts
    /// Only posts the account authored — reposts are skipped.
    case originalPostsOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off:               return "Off"
        case .allPosts:          return "All Posts"
        case .originalPostsOnly: return "Original Posts Only"
        }
    }
}

/// One followed account the user wants post notifications from.
public struct UserNotificationSubscription: Codable, Identifiable, Sendable, Equatable {
    public var id: String { did }
    public let did: String
    public var handle: String
    public var displayName: String?
    public var mode: UserPostNotificationMode

    public init(did: String, handle: String, displayName: String? = nil, mode: UserPostNotificationMode) {
        self.did = did
        self.handle = handle
        self.displayName = displayName
        self.mode = mode
    }
}

// MARK: - Feed alerts
/// One thing worth telling the user about, produced by the background
/// sync engine and handed to the platform's alert presenter (local
/// notifications on Apple platforms).
public struct FeedAlert: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// A social interaction on the user's own content (like, repost, …).
        case interaction(NotificationItem.NotificationReason)
        /// A new post from a subscribed account.
        case newPost(authorDID: String)
    }

    /// Stable identity (the source record's URI) so repeated sync passes
    /// can never present the same alert twice.
    public let id: String
    public let title: String
    public let body: String
    public let kind: Kind

    public init(id: String, title: String, body: String, kind: Kind) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
    }
}
