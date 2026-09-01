import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Theme preference keys
// UserDefaults-backed via @AppStorage. The scheme mirrors the {m.txt}
// editor's preference system (../minimalist), whose theme model this app
// reuses — same appearance trio, same accent-preset picker.
enum ThemeKeys {
    /// "system" | "light" | "dark" — the auto/light/dark appearance choice.
    static let colorScheme = "atmo.pref.colorScheme"
    /// Selected AccentPreset id.
    static let accentPresetID = "atmo.pref.accentPresetID"
    /// On/off — wash the app background (and opaque card surfaces) with a
    /// muted shade of the accent: pale in light mode, deep in dark mode.
    static let tintedBackground = "atmo.pref.tintedBackground"

    // Accessibility
    /// On/off — replace translucent glass card surfaces with opaque fills.
    static let solidSurfaces = "atmo.pref.solidSurfaces"
    /// On/off — disable in-app animations (springs, transitions).
    static let reduceMotion = "atmo.pref.reduceMotion"
    /// "default" | "large" | "xLarge" | "xxLarge" — in-app text size boost (iOS).
    static let textSize = "atmo.pref.textSize"
}

// MARK: - Appearance
enum AppearanceOption: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Auto"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// nil = follow the system (auto).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - Text size (accessibility)
enum TextSizeOption: String, CaseIterable, Identifiable {
    case standard = "default"
    case large
    case xLarge
    case xxLarge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Default"
        case .large:    return "Large"
        case .xLarge:   return "Extra Large"
        case .xxLarge:  return "Huge"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard: return .large       // the system default size
        case .large:    return .xLarge
        case .xLarge:   return .xxLarge
        case .xxLarge:  return .xxxLarge
        }
    }
}

// MARK: - Accent presets
/// One named entry in the accent-color picker. The palette is carried
/// over from the {m.txt} editor: names lean on Japanese aesthetic
/// concepts and a few stoic terms — the through-line is "quiet,
/// grounded, considered." Atmo adds its own Sky preset (the Bluesky
/// brand blue) as the default.
struct AccentPreset: Identifiable, Hashable {
    let id: String
    let displayName: String
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

enum AccentPresets {
    static let all: [AccentPreset] = [
        // Sky — the Bluesky brand blue; Atmo's own default.
        AccentPreset(id: "sky",        displayName: "Sky",        red: 0.00, green: 0.52, blue: 1.00),
        // Matcha — powdered tea green.
        AccentPreset(id: "matcha",     displayName: "Matcha",     red: 0.55, green: 0.72, blue: 0.42),
        // Sakura — cherry blossom; a quiet pink.
        AccentPreset(id: "sakura",     displayName: "Sakura",     red: 0.91, green: 0.65, blue: 0.71),
        // Ai — traditional indigo dye.
        AccentPreset(id: "ai",         displayName: "Ai",         red: 0.36, green: 0.49, blue: 0.65),
        // Kintsugi — the lacquered-gold mend of broken pottery.
        AccentPreset(id: "kintsugi",   displayName: "Kintsugi",   red: 0.83, green: 0.63, blue: 0.33),
        // Hinoki — Japanese cypress; warm wood tone.
        AccentPreset(id: "hinoki",     displayName: "Hinoki",     red: 0.79, green: 0.57, blue: 0.37),
        // Yūgen — depth and mystery; a twilight purple.
        AccentPreset(id: "yugen",      displayName: "Yūgen",      red: 0.48, green: 0.42, blue: 0.58),
        // Shibui — restrained, refined astringent beauty; muted teal.
        AccentPreset(id: "shibui",     displayName: "Shibui",     red: 0.43, green: 0.64, blue: 0.59),
        // Sumi — calligraphy-ink charcoal.
        AccentPreset(id: "sumi",       displayName: "Sumi",       red: 0.30, green: 0.32, blue: 0.36),
        // Ataraxia — Stoic tranquility; a pale dusk blue.
        AccentPreset(id: "ataraxia",   displayName: "Ataraxia",   red: 0.50, green: 0.62, blue: 0.72),
    ]

    static let defaultID = "sky"

    static func preset(forID id: String) -> AccentPreset {
        all.first { $0.id == id } ?? all[0]
    }

    /// Read the user's currently-selected accent preset from UserDefaults.
    /// Lives outside SwiftUI so non-reactive code paths can resolve the
    /// color without an `@AppStorage`.
    ///
    /// Cached by preset id: this is hit several times per feed row render
    /// (every tinted glyph and link color), so the linear preset search
    /// only reruns when the user actually changes the accent.
    private static var cachedID: String? = nil
    private static var cachedPreset: AccentPreset = all[0]

    static var current: AccentPreset {
        let id = UserDefaults.standard.string(forKey: ThemeKeys.accentPresetID) ?? defaultID
        if id != cachedID {
            cachedID = id
            cachedPreset = preset(forID: id)
        }
        return cachedPreset
    }
}

// MARK: - Tinted backdrop shades
// The "Tinted background" option derives every shade from the selected
// accent preset, deliberately de-vibranced: the accent is first pulled
// toward its own gray (so a vivid Sky washes out to the same quiet level
// as a muted Sumi), then mixed almost entirely into white (light mode) or
// near-black (dark mode). Content — text, media, cards — stays readable;
// the color reads as atmosphere, not paint.
extension AccentPreset {
    /// The accent pulled 40% toward its own luminance (gray).
    private var softened: (r: Double, g: Double, b: Double) {
        let luma = 0.299 * red + 0.587 * green + 0.114 * blue
        return (
            red * 0.6 + luma * 0.4,
            green * 0.6 + luma * 0.4,
            blue * 0.6 + luma * 0.4
        )
    }

    /// Muted app-background wash: a pale tint of the accent in light mode,
    /// a deep shade of it in dark mode.
    func backdropColor(for scheme: ColorScheme) -> Color {
        let s = softened
        if scheme == .dark {
            return Color(
                red: s.r * 0.22 + 0.035,
                green: s.g * 0.22 + 0.035,
                blue: s.b * 0.22 + 0.045
            )
        }
        return Color(
            red: 0.88 + s.r * 0.115,
            green: 0.88 + s.g * 0.115,
            blue: 0.88 + s.b * 0.115
        )
    }

    /// Companion card surface for the backdrop — one step lighter than the
    /// backdrop in both modes, so opaque cards ("Solid surfaces") still
    /// read as raised when translucent materials are off.
    func surfaceColor(for scheme: ColorScheme) -> Color {
        let s = softened
        if scheme == .dark {
            return Color(
                red: s.r * 0.26 + 0.06,
                green: s.g * 0.26 + 0.06,
                blue: s.b * 0.26 + 0.07
            )
        }
        return Color(
            red: 0.93 + s.r * 0.07,
            green: 0.93 + s.g * 0.07,
            blue: 0.93 + s.b * 0.07
        )
    }
}

// MARK: - Themed backdrop application
/// Paints the accent-derived wash behind a navigation shell's content and
/// lets scrollable containers (List, Form) show it through. Applied to
/// each platform shell's NavigationStack and to its pushed destinations —
/// sheets deliberately keep the system presentation background.
///
/// The app's translucent materials (glass cards, bars, the neumorphic
/// content cards) sample whatever sits behind them, so the wash carries
/// into those surfaces automatically — no per-element tinting needed.
struct ThemedBackdropModifier: ViewModifier {
    @AppStorage(ThemeKeys.tintedBackground) private var tintedBackground: Bool = false
    @AppStorage(ThemeKeys.accentPresetID) private var accentID: String = AccentPresets.defaultID
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if tintedBackground {
            content
                .scrollContentBackground(.hidden)
                .background {
                    AccentPresets.preset(forID: accentID)
                        .backdropColor(for: colorScheme)
                        .ignoresSafeArea()
                }
        } else {
            content
        }
    }
}

extension View {
    /// Applies the user's tinted-background wash (Settings → Appearance),
    /// when enabled. No-op otherwise.
    func themedBackdrop() -> some View {
        modifier(ThemedBackdropModifier())
    }
}

// MARK: - Non-reactive preference reads
/// For code that can't observe @AppStorage (design-system modifiers,
/// static styling helpers). Views that must react immediately hold their
/// own @AppStorage for the same keys.
enum ThemePreferences {
    static var solidSurfaces: Bool {
        UserDefaults.standard.bool(forKey: ThemeKeys.solidSurfaces)
    }
    static var reduceMotion: Bool {
        UserDefaults.standard.bool(forKey: ThemeKeys.reduceMotion)
    }
}

// MARK: - Root theme application
/// Applied once at the app root: appearance (auto/light/dark), the accent
/// tint, the in-app text size, and the reduce-motion override. All four
/// react live to settings changes through @AppStorage.
struct AtmoThemeModifier: ViewModifier {
    @AppStorage(ThemeKeys.colorScheme) private var schemeRaw: String = AppearanceOption.system.rawValue
    @AppStorage(ThemeKeys.accentPresetID) private var accentID: String = AccentPresets.defaultID
    @AppStorage(ThemeKeys.textSize) private var textSizeRaw: String = TextSizeOption.standard.rawValue
    @AppStorage(ThemeKeys.reduceMotion) private var reduceMotion: Bool = false

    func body(content: Content) -> some View {
        let appearance = AppearanceOption(rawValue: schemeRaw) ?? .system

        content
            .tint(AccentPresets.preset(forID: accentID).color)
#if os(macOS)
            // On macOS, preferredColorScheme propagates as a view
            // preference through the split view and each pane re-resolves
            // on its own schedule — a visible half-light/half-dark limbo.
            // Setting the appearance on NSApp flips every window at once
            // with the system's native crossfade.
            .onAppear { Self.applyMacAppearance(appearance) }
            .onChange(of: schemeRaw) { _, newValue in
                Self.applyMacAppearance(AppearanceOption(rawValue: newValue) ?? .system)
            }
#else
            .preferredColorScheme(appearance.colorScheme)
            .dynamicTypeSize((TextSizeOption(rawValue: textSizeRaw) ?? .standard).dynamicTypeSize)
#endif
            // Root-level reduce-motion: nils out the animation on every
            // transaction in the subtree, covering both implicit
            // animations and withAnimation calls.
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                }
            }
    }

#if os(macOS)
    private static func applyMacAppearance(_ option: AppearanceOption) {
        switch option {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
#endif
}

extension View {
    /// Applies the user's theme settings (appearance, accent, text size,
    /// reduce motion) to this subtree. Use once, at the root.
    func atmoTheme() -> some View {
        modifier(AtmoThemeModifier())
    }
}
