import Foundation
import ATProtoKit
import Observation

@Observable
@MainActor
final class NotificationsViewModel {

    private(set) var notifications: [NotificationItem] = []
    private(set) var isLoading: Bool = false
    private(set) var error: Error? = nil
    private(set) var unreadCount: Int = 0
    private var seenAt: Date? = nil
    private var cursor: String? = nil
    private var hasMore: Bool = true

    private let service: ATProtoService

    init(service: ATProtoService) {
        self.service = service
    }

    func load() async {
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

    func loadMore() async {
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
