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

    /// The notification reasons this category shows; nil = show everything.
    /// Likes/Reposts fold in their via-repost variants.
    var reasons: Set<NotificationItem.NotificationReason>? {
        switch self {
        case .notifications: return nil
        case .follows:       return [.follow]
        case .replies:       return [.reply]
        case .mentions:      return [.mention]
        case .quotes:        return [.quote]
        case .reposts:       return [.repost, .repostViaRepost]
        case .likes:         return [.like, .likeViaRepost]
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
        guard let reasons = selectedCategory.reasons else { return notifications }
        return notifications.filter { reasons.contains($0.reason) }
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
            await resolveSubjectSnippets()
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
            await resolveSubjectSnippets()
        } catch {
            self.error = error
        }
    }

    /// Fills in the like/repost rows' snippets — the text of the user's
    /// own post that was liked or reposted. Runs after the list is already
    /// on screen: rows render immediately and snippets pop in as the
    /// batched `getPosts` lookups (25 URIs per request) come back.
    private func resolveSubjectSnippets() async {
        guard let kit = service.atProtoKit else { return }
        let uris = NotificationItem.unresolvedSubjectURIs(in: notifications)

        if !uris.isEmpty {
            var texts: [String: String] = [:]
            for start in stride(from: 0, to: uris.count, by: 25) {
                let chunk = Array(uris[start..<min(start + 25, uris.count)])
                guard let output = try? await kit.getPosts(chunk) else { continue }
                for post in output.posts {
                    if let record = post.record.getRecord(ofType: AppBskyLexicon.Feed.PostRecord.self) {
                        texts[post.uri] = record.text
                    }
                }
            }
            if !texts.isEmpty {
                notifications = NotificationItem.injectingSnippets(into: notifications, texts: texts)
            }
        }

        // Fallback for subscribed-post rows whose record carried no text:
        // pull that account's latest post and use its content.
        await resolveSubscribedLatestPosts()
    }

    /// "Shared a new post" rows normally get their text straight from the
    /// notification record; when that came back empty, fetch the author's
    /// latest post instead (one small page per unique account).
    private func resolveSubscribedLatestPosts() async {
        guard let kit = service.atProtoKit else { return }
        let authors = NotificationItem.subscribedAuthorsNeedingLatestPost(in: notifications)
        guard !authors.isEmpty else { return }

        var textsByAuthor: [String: String] = [:]
        for did in authors.prefix(10) {
            guard let output = try? await kit.getAuthorFeed(by: did, limit: 1),
                  let feedPost = output.feed.first,
                  let record = feedPost.post.record.getRecord(ofType: AppBskyLexicon.Feed.PostRecord.self),
                  !record.text.isEmpty else { continue }
            textsByAuthor[did] = record.text
        }
        guard !textsByAuthor.isEmpty else { return }
        notifications = NotificationItem.injectingLatestPosts(into: notifications, textsByAuthor: textsByAuthor)
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
