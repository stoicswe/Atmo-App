import SwiftUI
import AtmoCore
import ATProtoKit

struct MessageBubbleView: View {
    let message: MessageItem
    let isFromMe: Bool
    /// Burst grouping: consecutive messages from one sender within a minute
    /// share a single timestamp on the last of them.
    var showsTimestamp: Bool = true

    var body: some View {
        HStack {
            if isFromMe { Spacer(minLength: 60) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                if !message.text.isEmpty {
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
                }

                // A post shared into the chat: the same quote card the feed
                // uses, so tapping it opens the post right here in the app.
                if let record = message.embeddedRecord {
                    sharedPost(record)
                        .frame(maxWidth: 340, alignment: isFromMe ? .trailing : .leading)
                }

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

    @ViewBuilder
    private func sharedPost(_ record: AppBskyLexicon.Embed.RecordDefinition.View) -> some View {
        switch record.record {
        case .viewRecord(let viewRecord):
            QuotePostView(record: viewRecord)
        default:
            HStack(spacing: AtmoTheme.Spacing.sm) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text("Post unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(AtmoTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }
}
