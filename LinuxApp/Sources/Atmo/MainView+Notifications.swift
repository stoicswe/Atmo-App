import Adwaita
import Foundation
import AtmoCore

extension MainView {

    struct NotificationRowSnapshot: Identifiable, Equatable {
        let id: String
        let authorDID: String
        let author: String
        let avatarURL: URL?
        let action: String
        let icon: String
        let snippet: String?
        let time: String
        let isRead: Bool
        let postURI: String?
    }

    struct ActivityToggle: ToggleGroupItem {
        let id: String
        let icon: Icon?
        var showLabel: Bool { false }
    }

    var activityToggles: [ActivityToggle] {
        ActivityCategory.allCases.map {
            let icon: String
            switch $0 {
            case .notifications: icon = "preferences-system-notifications-symbolic"
            case .follows: icon = "contact-new-symbolic"
            case .replies: icon = "mail-reply-sender-symbolic"
            case .mentions: icon = "mail-unread-symbolic"
            case .quotes: icon = "format-text-italic-symbolic"
            case .reposts: icon = "atmo-repost-symbolic"
            case .likes: icon = "atmo-heart-filled-symbolic"
            }
            return ActivityToggle(id: $0.rawValue, icon: .custom(name: icon))
        }
    }

    var notificationRows: [NotificationRowSnapshot] {
        _ = tick
        return onMain {
            guard let model = AppSession.shared.notifications else { return [] }
            if let category = ActivityCategory(rawValue: activityCategory), model.selectedCategory != category {
                model.selectedCategory = category
            }
            return model.filteredNotifications.map { item in
                NotificationRowSnapshot(
                    id: item.uri,
                    authorDID: item.authorDID,
                    author: item.authorDisplayName ?? "@\(item.authorHandle)",
                    avatarURL: item.authorAvatarURL,
                    action: item.reason.displayText,
                    icon: notificationIcon(item.reason),
                    snippet: item.contentSnippet,
                    time: item.indexedAt.atmoFormatted(),
                    isRead: item.isRead,
                    postURI: item.associatedPostURI
                )
            }
        }
    }

    func notificationIcon(_ reason: NotificationItem.NotificationReason) -> String {
        switch reason {
        case .like, .likeViaRepost: return "atmo-heart-filled-symbolic"
        case .repost, .repostViaRepost: return "atmo-repost-symbolic"
        case .follow: return "contact-new-symbolic"
        case .mention: return "mail-unread-symbolic"
        case .reply: return "mail-reply-sender-symbolic"
        case .quote: return "format-text-italic-symbolic"
        case .verified, .unverified: return "atmo-verified-symbolic"
        default: return "preferences-system-notifications-symbolic"
        }
    }

    var notificationsLoading: Bool {
        _ = tick
        return onMain { AppSession.shared.notifications?.isLoading ?? false }
    }

    @ViewBuilder var notificationsPane: Body {
        let rows = notificationRows
        VStack(spacing: 0) {
            ToggleGroup(selection: $activityCategory, values: activityToggles)
                .halign(.center)
                .padding(8)
            Separator()
            if rows.isEmpty {
                if notificationsLoading {
                    Spinner()
                        .vexpand()
                        .valign(.center)
                } else {
                    StatusPage(
                        activityCategory == ActivityCategory.notifications.rawValue ? "No activity yet" : "No \(activityCategory.lowercased()) yet",
                        icon: .custom(name: "preferences-system-notifications-symbolic"),
                        description: "Likes, reposts, follows, and replies land here."
                    )
                    .vexpand()
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.id) { row in
                            notificationRow(row)
                            Separator()
                        }
                        loadMoreFooter(visible: true, loading: notificationsLoading) {
                            runCore { await AppSession.shared.notifications?.loadMore() }
                        }
                    }
                    .frame(maxWidth: 720)
                }
                .vexpand()
                .onBottomEdgeReached {
                    guard infiniteScrollEnabled else { return }
                    runCore { await AppSession.shared.notifications?.loadMore() }
                }
            }
        }
    }

    @ViewBuilder func notificationRow(_ row: NotificationRowSnapshot) -> Body {
        HStack(spacing: 10) {
            Symbol(icon: .custom(name: row.icon))
                .style(row.isRead ? "dim-label" : "accent")
                .valign(.start)
                .padding(4, .top)
            remoteAvatar(url: row.avatarURL, name: row.author, size: 32)
                .valign(.start)
                .onClick { openProfile(actor: row.authorDID) }
                .tooltip("View profile")
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.author)
                        .ellipsize()
                        .style("heading")
                        .halign(.start)
                    Text(row.action)
                        .ellipsize()
                        .style("dim-label")
                        .halign(.start)
                        .hexpand()
                    Text(row.time)
                        .style("dim-label")
                        .style("caption")
                        .halign(.end)
                }
                if let snippet = row.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .wrap()
                        .lines(2)
                        .ellipsize()
                        .style("dim-label")
                        .halign(.start)
                }
            }
            .hexpand()
            .onClick { openNotification(row) }
            if !row.isRead {
                Text("●")
                    .style("accent")
                    .valign(.start)
            }
        }
        .padding(10)
    }

    /// Follows open the profile; everything else opens the post.
    func openNotification(_ row: NotificationRowSnapshot) {
        if let uri = row.postURI {
            openThread(uri: uri)
        } else {
            openProfile(actor: row.authorDID)
        }
    }
}
