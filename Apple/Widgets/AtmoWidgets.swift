import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Widget Bundle
// The extension exists for the post-publish Live Activity — the app
// itself starts/updates it (PostPublishBridge); this target only renders.
@main
struct AtmoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PostPublishLiveActivity()
    }
}

// MARK: - Post Publish Live Activity
/// Lock Screen banner + Dynamic Island for a post being published in the
/// background: the thread's first-line preview, the current stage, and a
/// progress bar — ending in a checkmark ("Posted") or the failure notice.
struct PostPublishLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PostPublishAttributes.self) { context in
            LockScreenPublishView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusGlyph(state: context.state)
                        .font(.title3)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.summary)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.stageDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PublishProgressBar(state: context.state)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            } compactLeading: {
                StatusGlyph(state: context.state)
                    .font(.caption)
            } compactTrailing: {
                if context.state.isFinished || context.state.isFailed {
                    EmptyView()
                } else {
                    ProgressView(value: context.state.progress)
                        .progressViewStyle(.circular)
                        .tint(.cyan)
                        .frame(width: 18, height: 18)
                }
            } minimal: {
                StatusGlyph(state: context.state)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Shared pieces

/// Paper plane while working, checkmark on success, warning on failure.
private struct StatusGlyph: View {
    let state: PostPublishAttributes.ContentState

    var body: some View {
        if state.isFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if state.isFinished {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "paperplane.fill")
                .foregroundStyle(.cyan)
        }
    }
}

private struct PublishProgressBar: View {
    let state: PostPublishAttributes.ContentState

    var body: some View {
        ProgressView(value: state.isFinished ? 1 : state.progress)
            .progressViewStyle(.linear)
            .tint(state.isFailed ? .orange : .cyan)
    }
}

private struct LockScreenPublishView: View {
    let context: ActivityViewContext<PostPublishAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusGlyph(state: context.state)
                    .font(.body)
                Text(context.attributes.summary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(context.state.stageDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !context.state.isFailed {
                PublishProgressBar(state: context.state)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}
