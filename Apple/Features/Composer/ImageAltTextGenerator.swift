import Foundation
import Vision
import AtmoCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Image Alt-Text Generator
/// Describes an attached image for accessibility: the Vision framework
/// reads the image (scene/object classification + any visible text), and
/// Apple Intelligence's on-device model phrases the findings as natural
/// one-sentence alt text. When Apple Intelligence isn't available on the
/// device, a plain template built from the same findings is used instead.
/// Everything runs on-device; the image never leaves the phone.
enum ImageAltTextGenerator {

    /// Returns generated alt text, or nil when the image yields nothing
    /// worth saying (analysis failure or no confident observations).
    static func generate(for imageData: Data) async -> String? {
        let labels = (try? await classify(imageData)) ?? []
        let visibleText = (try? await recognizeText(imageData)) ?? []
        guard !labels.isEmpty || !visibleText.isEmpty else { return nil }

#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability,
               let phrased = try? await phrase(labels: labels, visibleText: visibleText) {
                return phrased
            }
        }
#endif
        return fallbackDescription(labels: labels, visibleText: visibleText)
    }

    // MARK: Vision

    /// Top confident scene/object labels, human-readable.
    private static func classify(_ data: Data) async throws -> [String] {
        let request = ClassifyImageRequest()
        let observations = try await request.perform(on: data)
        return observations
            .filter { $0.confidence > 0.35 }
            .prefix(4)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    /// Prominent text found in the image (signs, captions, screenshots).
    private static func recognizeText(_ data: Data) async throws -> [String] {
        let request = RecognizeTextRequest()
        let observations = try await request.perform(on: data)
        return observations
            .prefix(4)
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Apple Intelligence phrasing

#if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func phrase(labels: [String], visibleText: [String]) async throws -> String? {
        let session = LanguageModelSession(instructions: """
            You write alt text for images on social media: one concise, \
            factual sentence describing the image for someone using a \
            screen reader. No preamble, no quotation marks, no hedging \
            like "an image of".
            """)
        var prompt = "Detected contents of the image: \(labels.joined(separator: ", "))."
        if !visibleText.isEmpty {
            prompt += " Text visible in the image: \(visibleText.joined(separator: " / "))."
        }
        prompt += " Write the alt text."

        let response = try await session.respond(to: prompt)
        let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(500))
    }
#endif

    // MARK: Fallback (no Apple Intelligence)

    private static func fallbackDescription(labels: [String], visibleText: [String]) -> String? {
        var parts: [String] = []
        if !labels.isEmpty {
            parts.append("Image that may show \(labels.joined(separator: ", ")).")
        }
        if !visibleText.isEmpty {
            parts.append("Text in image: \(visibleText.joined(separator: " ")).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
