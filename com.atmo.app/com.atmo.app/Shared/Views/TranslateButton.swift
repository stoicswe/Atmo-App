import SwiftUI
import Translation

// MARK: - TranslateButton
// A small pill-shaped button that triggers Apple's native Translation sheet.
// The .translationPresentation modifier handles the entire UI and on-device inference.
struct TranslateButton: View {
    let text: String
    /// When non-nil, this is a *suggested* target language (e.g., the post's
    /// original language when composing a reply). Pass nil to let the system choose.
    var suggestedTarget: Locale.Language? = nil

    @State private var configuration: TranslationSession.Configuration?
    @State private var showTranslation: Bool = false

    var body: some View {
        Button {
            if configuration == nil {
                // Build a configuration: system picks source automatically;
                // we can optionally hint at the target for the composer reply case.
                configuration = TranslationSession.Configuration(
                    source: nil,   // auto-detect
                    target: suggestedTarget
                )
            } else {
                // Invalidate to force a fresh session (e.g., user taps again)
                configuration?.invalidate()
            }
            showTranslation = true
        } label: {
            Label("Translate", systemImage: "character.bubble")
                .font(.caption.weight(.medium))
                .foregroundStyle(AtmoColors.skyBlue)
                .padding(.horizontal, AtmoTheme.Spacing.sm)
                .padding(.vertical, 3)
                .background {
                    Capsule()
                        .fill(AtmoColors.skyBlue.opacity(0.10))
                        .strokeBorder(AtmoColors.skyBlue.opacity(0.25), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .translationPresentation(isPresented: $showTranslation, text: text)
    }
}
