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

    public enum NotificationReason: String, Sendable {
        case like
        case repost
        case follow
        case mention
        case reply
        case quote
        case unknown

        public var displayText: String {
            switch self {
            case .like:    return "liked your post"
            case .repost:  return "reposted your post"
            case .follow:  return "followed you"
            case .mention: return "mentioned you"
            case .reply:   return "replied to your post"
            case .quote:   return "quoted your post"
            case .unknown: return "interacted with you"
            }
        }

        public var icon: String {
            switch self {
            case .like:    return "heart.fill"
            case .repost:  return "arrow.2.squarepath"
            case .follow:  return "person.badge.plus.fill"
            case .mention: return "at"
            case .reply:   return "bubble.left.fill"
            case .quote:   return "quote.bubble.fill"
            case .unknown: return "bell.fill"
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
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: NotificationItem, rhs: NotificationItem) -> Bool { lhs.id == rhs.id }
}
