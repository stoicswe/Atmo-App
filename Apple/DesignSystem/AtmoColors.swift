import SwiftUI

enum AtmoColors {
    // MARK: - Primary Accent
    /// Sky blue — Bluesky brand color
    static let skyBlue = Color(red: 0, green: 133 / 255, blue: 1.0)

    // MARK: - Action Colors
    static let likeRed = Color(red: 1.0, green: 64 / 255, blue: 64 / 255)
    static let repostGreen = Color(red: 0, green: 186 / 255, blue: 124 / 255)
    static let quoteBlue = Color(red: 0, green: 133 / 255, blue: 1.0)

    // MARK: - Glass Surface Tints
    static let glassTint = Color(red: 0, green: 133 / 255, blue: 1.0).opacity(0.04)
    static let glassDivider = Color.white.opacity(0.12)
    static let glassBorder = Color.white.opacity(0.18)

    // MARK: - Text
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText: Color = {
#if os(iOS)
        Color(UIColor.tertiaryLabel)
#elseif os(macOS)
        Color(NSColor.tertiaryLabelColor)
#else
        Color.secondary
#endif
    }()

    // MARK: - Background Gradients
    static let skyGradient = LinearGradient(
        colors: [
            Color(red: 0.05, green: 0.35, blue: 0.85).opacity(0.35),
            Color(red: 0.02, green: 0.08, blue: 0.25).opacity(0.55)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Cross-Platform UIColor/NSColor Helper
private extension Color {
    init(uiOrNSColor: Any) {
#if os(iOS)
        if let uiColor = uiOrNSColor as? UIColor {
            self.init(uiColor)
        } else {
            self = .secondary
        }
#elseif os(macOS)
        if let nsColor = uiOrNSColor as? NSColor {
            self.init(nsColor)
        } else {
            self = .secondary
        }
#endif
    }
}
