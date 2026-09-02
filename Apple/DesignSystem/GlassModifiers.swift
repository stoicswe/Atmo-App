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

    // Accessibility: "Solid surfaces" swaps the glass for an opaque fill.
    @AppStorage(ThemeKeys.solidSurfaces) private var solidSurfaces: Bool = false
    // With Tinted background on, opaque cards take the accent-derived
    // surface shade so they match the wash materials sample for free.
    @AppStorage(ThemeKeys.tintedBackground) private var tintedBackground: Bool = false
    @AppStorage(ThemeKeys.accentPresetID) private var accentID: String = AccentPresets.defaultID
    @Environment(\.colorScheme) private var colorScheme

    private var solidFill: Color {
        tintedBackground
            ? AccentPresets.preset(forID: accentID).surfaceColor(for: colorScheme)
            : AtmoColors.solidSurface
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if solidSurfaces {
            content
                .background(solidFill, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        } else {
            content
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: shape
                )
        }
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

// MARK: - Glass Pill Buttons
/// Explicit Liquid Glass capsule for bar/header buttons. Used instead of
/// `.buttonStyle(.glass)` so macOS and iOS render the same thing — the
/// system style tints itself opaque inside macOS sheets.
struct GlassPillButtonStyle: ButtonStyle {
    var prominent: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, AtmoTheme.Spacing.md)
            .frame(height: 32)
            .contentShape(Capsule())
            .glassEffect(
                prominent
                    ? .regular.tint(AtmoColors.accent).interactive()
                    : .regular.interactive(),
                in: Capsule()
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassPillButtonStyle {
    static var glassPill: GlassPillButtonStyle { GlassPillButtonStyle() }
    static var glassPillProminent: GlassPillButtonStyle { GlassPillButtonStyle(prominent: true) }
}

// MARK: - Neumorphic Glass Card
/// A soft-UI ("neumorphism") take on a content card that still belongs to
/// the Liquid Glass era: the surface stays a system material, but the card
/// reads as gently extruded — a "lit from above" gradient rim plus the
/// classic dual soft shadows (dark toward bottom-trailing, light toward
/// top-leading). Deliberately subtle, and tuned per color scheme so the
/// highlight doesn't glow in dark mode or vanish in light mode.
///
/// Used for embedded content cards (quoted/reposted posts, link previews)
/// — the floating control layer keeps pure `glassEffect` instead.
struct NeumorphicGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = AtmoTheme.CornerRadius.medium
    @Environment(\.colorScheme) private var colorScheme

    // Accessibility: "Solid surfaces" swaps the material for an opaque
    // fill — which is in fact the *classic* neumorphic look; the rim and
    // dual shadows below still apply.
    @AppStorage(ThemeKeys.solidSurfaces) private var solidSurfaces: Bool = false
    // Tinted background: opaque cards take the accent-derived surface
    // shade (see GlassCardModifier).
    @AppStorage(ThemeKeys.tintedBackground) private var tintedBackground: Bool = false
    @AppStorage(ThemeKeys.accentPresetID) private var accentID: String = AccentPresets.defaultID

    private var solidFill: Color {
        tintedBackground
            ? AccentPresets.preset(forID: accentID).surfaceColor(for: colorScheme)
            : AtmoColors.solidSurface
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark

        content
            .background {
                if solidSurfaces {
                    shape.fill(solidFill)
                } else {
                    shape.fill(.thinMaterial)
                }
            }
            .clipShape(shape)
            .overlay {
                // Top-light rim — the extruded edge catching the light.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(dark ? 0.14 : 0.50),
                            .white.opacity(dark ? 0.02 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            // Flatten before shadowing so the shadows trace the card
            // silhouette, not every subview.
            .compositingGroup()
            .shadow(color: .black.opacity(dark ? 0.32 : 0.10), radius: 5, x: 2, y: 3)
            .shadow(color: .white.opacity(dark ? 0.04 : 0.50), radius: 5, x: -2, y: -3)
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

    /// Applies the soft-UI content-card treatment (see NeumorphicGlassCardModifier).
    func neumorphicGlassCard(cornerRadius: CGFloat = AtmoTheme.CornerRadius.medium) -> some View {
        modifier(NeumorphicGlassCardModifier(cornerRadius: cornerRadius))
    }

    /// Sets the app's sky-blue accent tint.
    func atmoTint() -> some View {
        tint(AtmoColors.accent)
    }
}
