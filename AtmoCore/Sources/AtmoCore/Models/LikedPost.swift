import Foundation

// MARK: - Liked Posts Retention
/// How long the Liked history keeps entries (Settings → Appearance).
/// Expiry removes entries from the history only — the likes themselves
/// stay untouched on Bluesky.
public enum LikedPostsRetention: String, CaseIterable, Identifiable, Sendable {
    case days14
    case days30
    case days90
    case months6
    case year1
    case never

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .days14:  return "14 Days"
        case .days30:  return "30 Days"
        case .days90:  return "90 Days"
        case .months6: return "6 Months"
        case .year1:   return "1 Year"
        // Reads as the answer to "Keep liked posts: …" — "Never" sounded
        // like keeping nothing at all.
        case .never:   return "Forever"
        }
    }

    /// Seconds an entry may age before expiring; nil = keep forever.
    public var maxAge: TimeInterval? {
        let day: TimeInterval = 86_400
        switch self {
        case .days14:  return 14 * day
        case .days30:  return 30 * day
        case .days90:  return 90 * day
        case .months6: return 182 * day
        case .year1:   return 365 * day
        case .never:   return nil
        }
    }

    /// UserDefaults/AppStorage key.
    public static let storageKey = "com.atmo.app.likedPosts.retention"
    public static let defaultValue: LikedPostsRetention = .never

    /// Non-reactive read for the store; the Settings picker holds its own
    /// @AppStorage on the same key.
    public static var current: LikedPostsRetention {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(LikedPostsRetention.init(rawValue:)) ?? defaultValue
    }
}

// MARK: - Liked Post
/// Codable snapshot of a post the user liked, mirroring BookmarkedPost:
/// just enough to render the Liked list row and navigate to the thread.
/// Recorded when a like succeeds, removed when the unlike does.
public struct LikedPost: Codable, Identifiable, Equatable, Sendable {
    public let id: String          // == uri, canonical identity
    public let uri: String
    public let cid: String
    public let authorDID: String
    public let authorHandle: String
    public let authorDisplayName: String?
    public let authorAvatarURLString: String?
    public let text: String
    public let indexedAt: Date
    public let likedAt: Date

    public var authorAvatarURL: URL? {
        authorAvatarURLString.flatMap { URL(string: $0) }
    }

    public init(post: PostItem, likedAt: Date = Date()) {
        self.id             = post.uri
        self.uri            = post.uri
        self.cid            = post.cid
        self.authorDID      = post.authorDID
        self.authorHandle   = post.authorHandle
        self.authorDisplayName = post.authorDisplayName
        self.authorAvatarURLString = post.authorAvatarURL?.absoluteString
        self.text           = post.text
        self.indexedAt      = post.indexedAt
        self.likedAt        = likedAt
    }
}
