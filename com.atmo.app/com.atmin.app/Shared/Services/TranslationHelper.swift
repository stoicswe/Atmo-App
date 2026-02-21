import Foundation
import NaturalLanguage

// MARK: - TranslationHelper
// Pure-logic utilities for language detection.
// This file deliberately imports only Foundation + NaturalLanguage (no SwiftUI)
// so that Swift 6 does NOT infer @MainActor on the static methods, allowing them
// to be called safely from Task.detached and other non-isolated contexts.
enum TranslationHelper {

    /// Detects the dominant language of a string.
    /// Returns nil if the text is too short or ambiguous.
    static func detectedLanguage(of text: String) -> Locale.Language? {
        guard text.count > 10 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage,
              dominant != .undetermined else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }

    /// Returns true when the post appears to be in a language different from
    /// the user's primary preferred language, meaning a translate button should show.
    static func needsTranslation(_ text: String) -> Bool {
        guard let detected = detectedLanguage(of: text) else { return false }
        // Use the user's first preferred language (e.g. "en", "fr", "ja")
        let preferred = Locale.preferredLanguages.first.map { Locale.Language(identifier: $0) }
        guard let preferred else { return false }
        // Compare language codes (ignores region: "en-US" == "en-GB" → same)
        return detected.languageCode != preferred.languageCode
    }
}
