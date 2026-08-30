import Adwaita
import Foundation
import AtmoCore

extension MainView {

    struct NotificationRowSnapshot: Identifiable, Equatable {
        let id: String
        let author: String
        let action: String
        let time: String
        let isRead: Bool
    }

    var notificationRows: [NotificationRowSnapshot] {
        _ = tick
        return onMain {
            (AppSession.shared.notifications?.notifications ?? []).map { item in
                NotificationRowSnapshot(
                    id: item.uri,
                    author: item.authorDisplayName ?? item.authorHandle,
                    action: item.reason.displayText,
                    time: item.indexedAt.atmoFormatted(),
                    isRead: item.isRead
                )
            }
        }
    }

    @ViewBuilder var notificationsPane: Body {
        let rows = notificationRows
        if rows.isEmpty {
            StatusPage(
                "No activity yet",
                icon: .custom(name: "preferences-system-notifications-symbolic"),
                description: "Likes, reposts, follows, and replies land here."
            )
            .vexpand()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.id) { row in
                        notificationRow(row)
                        Separator()
                    }
                }
            }
            .vexpand()
        }
    }

    @ViewBuilder func notificationRow(_ row: NotificationRowSnapshot) -> Body {
        HStack(spacing: 8) {
            Text(row.isRead ? " " : "●")
                .style("accent")
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.author)
                        .style("heading")
                        .halign(.start)
                    Text(row.time)
                        .style("dim-label")
                        .hexpand()
                        .halign(.end)
                }
                Text(row.action)
                    .style("dim-label")
                    .halign(.start)
            }
            .hexpand()
        }
        .padding(10)
    }
}
