import SwiftUI

// MARK: - Glass Card Modifier
/// Applies a native Liquid Glass card background with rounded corners.
///
/// `.glassEffect()` renders the full glass treatment on its own —
/// backdrop refraction, edge highlight, and shape clipping. Layering it
/// over a material fill (the pre-Liquid-Glass approach) muddies the
/// refraction, so the glass stands alone here.
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = AtmoTheme.CornerRadius.large
    var interactive: Bool = false

    func body(content: Content) -> some View {
        content
            .glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

// MARK: - Glass Row Modifier
/// Lightweight material background for feed rows. Content-layer surfaces
/// deliberately stay material — Liquid Glass is reserved for the floating
/// control layer per the platform HIG.
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
            .glassEffect(.regular.interactive(), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - View Extensions
extension View {
    /// Applies a native Liquid Glass card background.
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
