import SwiftUI

enum AtmoTheme {
    // MARK: - Corner Radii
    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 24
        static let pill: CGFloat = 999
    }

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Shadows
    enum Shadow {
        static let subtle = ShadowStyle(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        static let card = ShadowStyle(color: .black.opacity(0.10), radius: 12, x: 0, y: 4)
        static let floating = ShadowStyle(color: .black.opacity(0.18), radius: 24, x: 0, y: 8)
    }

    // MARK: - Avatar Sizes
    enum AvatarSize {
        static let small: CGFloat = 32
        static let medium: CGFloat = 44
        static let large: CGFloat = 64
        static let profile: CGFloat = 80
    }

    // MARK: - Feed
    enum Feed {
        static let horizontalPadding: CGFloat = 16
        static let verticalPadding: CGFloat = 12
        static let avatarSize: CGFloat = 44
        static let avatarTextSpacing: CGFloat = 10
    }
}

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension View {
    func atmoShadow(_ style: ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
