import SwiftUI
import AtmoCore
import ATProtoKit

// MARK: - Message Bubble
// iMessage-style bubbles: accent for the person's own messages, a soft
// gray for the other side, a tail on the last bubble of a burst, and
// tight spacing inside a burst. A shared post renders as the feed's
// quote card (tap opens it); a lone GIF link plays inline.
struct MessageBubbleView: View {
    let message: MessageItem
    let isFromMe: Bool
    /// Burst grouping: consecutive messages from one sender within a minute
    /// share a single timestamp on the last of them — that bubble also
    /// wears the tail.
    var showsTimestamp: Bool = true

    private var gifLink: GIFLink? {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), !trimmed.contains("\n") else { return nil }
        return GIFLink.parse(trimmed)
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if isFromMe { Spacer(minLength: 60) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 3) {
                if let record = message.embeddedRecord {
                    embeddedPost(record)
                        .frame(maxWidth: 320, alignment: isFromMe ? .trailing : .leading)
                }

                if let gifLink {
                    GIFEmbedView(link: gifLink, thumbnailURL: nil, altText: "GIF") {
                        textBubble
                    }
                    .frame(maxWidth: 240)
                } else if !message.text.isEmpty {
                    textBubble
                }

                if showsTimestamp {
                    Text(message.sentAt.atmoFormatted())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, AtmoTheme.Spacing.xs)
                        .padding(.top, 1)
                }
            }

            if !isFromMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.top, showsTimestamp ? 2 : 1)
        .padding(.bottom, showsTimestamp ? AtmoTheme.Spacing.sm : 1)
    }

    private var bubbleColor: Color {
        isFromMe ? AtmoColors.accent : Color.secondary.opacity(0.18)
    }

    private var textBubble: some View {
        Text(message.text)
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(isFromMe ? .white : .primary)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(alignment: isFromMe ? .bottomTrailing : .bottomLeading) {
                if showsTimestamp {
                    BubbleTail()
                        .fill(bubbleColor)
                        .frame(width: 13, height: 15)
                        .scaleEffect(x: isFromMe ? 1 : -1)
                        .offset(x: isFromMe ? 5 : -5, y: 0)
                }
            }
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func embeddedPost(_ record: AppBskyLexicon.Embed.RecordDefinition.View) -> some View {
        switch record.record {
        case .viewRecord(let view):
            QuotePostView(record: view)
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

// MARK: - Bubble Tail
/// The little curl at a bubble's bottom corner, drawn for the trailing
/// side; mirrored for the leading side. Its left edge sits inside the
/// bubble so the two shapes read as one.
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: h))
        // Bottom edge sweeps out to the tip…
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w * 0.55, y: h))
        // …and the outer edge curls back up into the bubble.
        p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: w * 0.15, y: h * 0.55))
        p.closeSubpath()
        return p
    }
}
