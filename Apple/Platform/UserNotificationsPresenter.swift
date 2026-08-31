import Foundation
import UserNotifications
import AtmoCore

/// Presents background-sync alerts as local user notifications.
/// Alert identifiers are the source records' URIs, so a repeated sync
/// pass can never show a duplicate — the notification center replaces
/// requests with the same identifier.
struct UserNotificationsPresenter: AlertPresenting {

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func present(_ alerts: [FeedAlert]) async {
        guard !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        // Cap a single pass so a busy hour never floods the shade.
        for alert in alerts.prefix(10) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            // Group interaction alerts and per-author post alerts into
            // their own notification-center stacks.
            switch alert.kind {
            case .interaction:
                content.threadIdentifier = "atmo.interactions"
            case .newPost(let authorDID):
                content.threadIdentifier = "atmo.posts.\(authorDID)"
            case .directMessage(let conversationID):
                // One stack per conversation, like Messages.
                content.threadIdentifier = "atmo.dms.\(conversationID)"
            }

            let request = UNNotificationRequest(
                identifier: alert.id,
                content: content,
                trigger: nil // deliver now
            )
            try? await center.add(request)
        }
    }
}
