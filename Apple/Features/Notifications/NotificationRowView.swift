import SwiftUI
import AtmoCore

struct NotificationRowView: View {
    let notification: NotificationItem

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Spacing.md) {
            // Reason icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: notification.reason.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                // Author + action
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    // The avatar opens the profile of whoever caused the
                    // notification. Pushes their DID — both app nav stacks
                    // resolve String destinations to ProfileView.
                    NavigationLink(value: notification.authorDID) {
                        AvatarView(url: notification.authorAvatarURL, size: 22)
                            // 22 pt is below a comfortable touch target —
                            // widen the tappable circle without moving layout.
                            .contentShape(Circle().inset(by: -11))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "View profile of \(notification.authorDisplayName ?? notification.authorHandle)"
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if let name = notification.authorDisplayName {
                                Text(name).fontWeight(.semibold)
                            } else {
                                Text("@\(notification.authorHandle)").fontWeight(.semibold)
                            }
                            Text(notification.reason.displayText)
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)

                        Text(notification.indexedAt.atmoFormatted())
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // A taste of the content behind the notification: the
                // liked/reposted post's text, or the reply/quote/mention's
                // own words.
                if let snippet = notification.contentSnippet,
                   !snippet.isEmpty {
                    Text(snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            // Unread indicator
            if !notification.isRead {
                Circle()
                    .fill(AtmoColors.accent)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.md)
        .contentShape(Rectangle())
    }

    private var iconColor: Color {
        switch notification.reason {
        case .like, .likeViaRepost:     return AtmoColors.likeRed
        case .repost, .repostViaRepost: return AtmoColors.repostGreen
        case .follow, .subscribedPost,
             .starterpackJoined,
             .verified:                 return AtmoColors.accent
        default:                        return .secondary
        }
    }
}
