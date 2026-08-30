import Foundation
import ATProtoKit
import Observation

// MARK: - Activity Category
/// The pill-tab filters of the Activity section: everything, then one tab
/// per Bluesky notification reason.
public enum ActivityCategory: String, CaseIterable, Identifiable, Sendable {
    case notifications = "Notifications"
    case follows = "Follows"
    case replies = "Replies"
    case mentions = "Mentions"
    case quotes = "Quotes"
    case reposts = "Reposts"
    case likes = "Likes"

    public var id: String { rawValue }

    /// SF Symbol for the pill.
    public var icon: String {
        switch self {
        case .notifications: return "bell"
        case .follows:       return "person.badge.plus"
        case .replies:       return "bubble.left"
        case .mentions:      return "at"
        case .quotes:        return "quote.bubble"
        case .reposts:       return "arrow.2.squarepath"
        case .likes:         return "heart"
        }
    }

    /// The notification reason this category shows; nil = show everything.
    var reason: NotificationItem.NotificationReason? {
        switch self {
        case .notifications: return nil
        case .follows:       return .follow
        case .replies:       return .reply
        case .mentions:      return .mention
        case .quotes:        return .quote
        case .reposts:       return .repost
        case .likes:         return .like
        }
    }
}

@Observable
@MainActor
public final class NotificationsViewModel {

    public private(set) var notifications: [NotificationItem] = []

    /// The active Activity pill. Filtering is client-side over the loaded
    /// pages, so switching tabs is instant.
    public var selectedCategory: ActivityCategory = .notifications

    /// The notifications matching the active category.
    public var filteredNotifications: [NotificationItem] {
        guard let reason = selectedCategory.reason else { return notifications }
        return notifications.filter { $0.reason == reason }
    }
    public private(set) var isLoading: Bool = false
    public private(set) var error: Error? = nil
    public private(set) var unreadCount: Int = 0
    private var seenAt: Date? = nil
    private var cursor: String? = nil
    private var hasMore: Bool = true

    private let service: ATProtoService

    public init(service: ATProtoService) {
        self.service = service
    }

    public func load() async {
        guard let kit = service.atProtoKit else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let output = try await kit.listNotifications(limit: 50)
            notifications = output.notifications.map { NotificationItem(notification: $0) }
            unreadCount = notifications.filter { !$0.isRead }.count
            cursor = output.cursor
            hasMore = output.cursor != nil
            error = nil
            // Mark as seen after loading
            await markSeen()
        } catch {
            self.error = error
        }
    }

    public func loadMore() async {
        guard hasMore, !isLoading, let cursor = cursor else { return }
        guard let kit = service.atProtoKit else { return }
        do {
            let output = try await kit.listNotifications(limit: 50, cursor: cursor)
            let newItems = output.notifications.map { NotificationItem(notification: $0) }
            notifications.append(contentsOf: newItems)
            self.cursor = output.cursor
            hasMore = output.cursor != nil
        } catch {
            self.error = error
        }
    }

    private func markSeen() async {
        guard let kit = service.atProtoKit else { return }
        do {
            try await kit.updateSeen(seenAt: Date())
            unreadCount = 0
        } catch {
            // Non-critical
        }
    }
}
