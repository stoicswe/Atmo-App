import SwiftUI
import AtmoCore

// MARK: - VerifiedBadge
// Bluesky verification seal, shown beside display names. Uses Bluesky's
// canonical blue (not the user's accent) so verification reads the same
// in every theme, matching the official app.
struct VerifiedBadge: View {
    let badge: VerificationBadge
    var size: CGFloat = 12

    private static let blueskyBlue = Color(red: 0.063, green: 0.514, blue: 0.996)

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Self.blueskyBlue)
            .accessibilityLabel(
                badge == .trustedVerifier ? "Trusted verifier" : "Verified account"
            )
    }
}
