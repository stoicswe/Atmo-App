import SwiftUI

struct MessageBubbleView: View {
    let message: MessageItem
    let isFromMe: Bool

    var body: some View {
        HStack {
            if isFromMe { Spacer(minLength: 60) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .padding(.horizontal, AtmoTheme.Spacing.md)
                    .padding(.vertical, AtmoTheme.Spacing.sm)
                    .background(
                        isFromMe ? AtmoColors.skyBlue : Color.secondary.opacity(0.15)
                    )
                    .foregroundStyle(isFromMe ? .white : .primary)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: AtmoTheme.CornerRadius.large,
                            style: .continuous
                        )
                    )

                Text(message.sentAt.atmoFormatted())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, AtmoTheme.Spacing.xs)
            }

            if !isFromMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.xs)
    }
}
