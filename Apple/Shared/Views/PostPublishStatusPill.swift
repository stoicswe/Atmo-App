#if os(iOS)
import SwiftUI
import AtmoCore

// MARK: - Post Publish Status Pill
/// In-app twin of the publish Live Activity: a glass capsule at the top
/// of the shell showing the current background publish — stage text with
/// a progress ring while working, a brief "Posted" confirmation, or the
/// failure notice (tap to dismiss) pointing at the saved draft.
struct PostPublishStatusPill: View {
    private let publisher = PostPublisher.shared

    /// Keeps the finished/failed state visible briefly after the job ends.
    @State private var transientVisible = false

    var body: some View {
        Group {
            switch publisher.phase {
            case .preparingMedia, .posting:
                pill(
                    icon: nil,
                    text: PostPublisher.describe(publisher.phase),
                    showsProgress: true
                )
            case .finished:
                if transientVisible {
                    pill(icon: ("checkmark.circle.fill", Color.green), text: "Posted", showsProgress: false)
                }
            case .failed(let message):
                if transientVisible {
                    pill(icon: ("exclamationmark.triangle.fill", Color.orange), text: message, showsProgress: false)
                        .onTapGesture { transientVisible = false }
                }
            case .idle:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: publisher.phase)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: transientVisible)
        .task(id: publisher.phase) {
            switch publisher.phase {
            case .finished:
                transientVisible = true
                try? await Task.sleep(for: .seconds(2.5))
                transientVisible = false
            case .failed:
                transientVisible = true
                try? await Task.sleep(for: .seconds(8))
                transientVisible = false
            default:
                break
            }
        }
    }

    private func pill(icon: (name: String, tint: Color)?, text: String, showsProgress: Bool) -> some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            if showsProgress {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.04, publisher.progress))
                        .stroke(AtmoColors.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: publisher.progress)
                }
                .frame(width: 16, height: 16)
            } else if let icon {
                Image(systemName: icon.name)
                    .font(.footnote)
                    .foregroundStyle(icon.tint)
            }

            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, AtmoTheme.Spacing.md)
        .padding(.vertical, AtmoTheme.Spacing.sm)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, AtmoTheme.Spacing.xl)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}
#endif
