import SwiftUI

/// Consistent full-screen or inline loading state with optional message.
struct LoadingView: View {
    var message: String = "Loading…"
    var compact: Bool = false

    var body: some View {
        VStack(spacing: AtmoTheme.Spacing.md) {
            ProgressView()
                .controlSize(compact ? .small : .regular)
                .tint(AtmoColors.skyBlue)
            if !compact {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .padding(AtmoTheme.Spacing.xxl)
    }
}
