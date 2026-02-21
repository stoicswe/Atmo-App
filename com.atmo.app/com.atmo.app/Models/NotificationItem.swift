import Foundation
import ATProtoKit

struct NotificationItem: Identifiable, Hashable {
    let id: String  // == uri
    let uri: String
    let cid: String

    let authorDID: String
    let authorHandle: String
    let authorDisplayName: String?
    let authorAvatarURL: URL?

    let reason: NotificationReason
    let isRead: Bool
    let indexedAt: Date

    // Optionally associated post
    let associatedPostURI: String?

    enum NotificationReason: String {
        case like
        case repost
        case follow
        case mention
        case reply
        case quote
        case unknown

        var displayText: String {
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

        var icon: String {
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

    init(notification: AppBskyLexicon.Notification.Notification) {
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

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: NotificationItem, rhs: NotificationItem) -> Bool { lhs.id == rhs.id }
}
