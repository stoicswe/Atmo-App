import SwiftUI

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
                    AvatarView(url: notification.authorAvatarURL, size: 22)
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
            }

            Spacer()

            // Unread indicator
            if !notification.isRead {
                Circle()
                    .fill(AtmoColors.skyBlue)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.md)
        .contentShape(Rectangle())
    }

    private var iconColor: Color {
        switch notification.reason {
        case .like:   return AtmoColors.likeRed
        case .repost: return AtmoColors.repostGreen
        case .follow: return AtmoColors.skyBlue
        default:      return .secondary
        }
    }
}
