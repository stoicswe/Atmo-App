import SwiftUI
import AtmoCore

struct MessageBubbleView: View {
    let message: MessageItem
    let isFromMe: Bool
    /// Burst grouping: consecutive messages from one sender within a minute
    /// share a single timestamp on the last of them.
    var showsTimestamp: Bool = true

    var body: some View {
        HStack {
            if isFromMe { Spacer(minLength: 60) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .padding(.horizontal, AtmoTheme.Spacing.md)
                    .padding(.vertical, AtmoTheme.Spacing.sm)
                    .background(
                        isFromMe ? AtmoColors.accent : Color.secondary.opacity(0.15)
                    )
                    .foregroundStyle(isFromMe ? .white : .primary)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: AtmoTheme.CornerRadius.large,
                            style: .continuous
                        )
                    )

                if showsTimestamp {
                    Text(message.sentAt.atmoFormatted())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, AtmoTheme.Spacing.xs)
                }
            }

            if !isFromMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.xs)
    }
}
