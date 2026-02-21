import SwiftUI

/// A dismissible error banner that optionally offers a retry action.
struct ErrorBannerView: View {
    let message: String
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer()

            if let onRetry = onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(AtmoColors.skyBlue)
            }
        }
        .padding(AtmoTheme.Spacing.md)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
        .atmoShadow(AtmoTheme.Shadow.card)
        .padding(AtmoTheme.Spacing.md)
    }
}
