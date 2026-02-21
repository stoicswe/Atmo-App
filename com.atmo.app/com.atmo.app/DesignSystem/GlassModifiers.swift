import SwiftUI

// MARK: - Glass Card Modifier
/// Applies a Liquid Glass card background with rounded corners.
/// Uses iOS 26 / macOS 26 native .glassEffect() for true dynamic glass rendering.
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = AtmoTheme.CornerRadius.large
    var interactive: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape
                    .fill(.ultraThinMaterial)
                    .glassEffect(
                        interactive ? .regular.interactive() : .regular,
                        in: shape
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .atmoShadow(AtmoTheme.Shadow.card)
    }
}

// MARK: - Glass Row Modifier
/// Lightweight glass background for feed rows (no shadow, no clip).
struct GlassRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.thinMaterial)
    }
}

// MARK: - Floating Glass Button
struct FloatingGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(AtmoTheme.Spacing.md)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - View Extensions
extension View {
    /// Applies a Liquid Glass card background.
    func glassCard(cornerRadius: CGFloat = AtmoTheme.CornerRadius.large, interactive: Bool = false) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// Applies a thin material background for feed rows.
    func glassRow() -> some View {
        modifier(GlassRowModifier())
    }

    /// Sets the app's sky-blue accent tint.
    func atmoTint() -> some View {
        tint(AtmoColors.skyBlue)
    }
}
