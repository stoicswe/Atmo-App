import SwiftUI
import AtmoCore
#if canImport(SensitiveContentAnalysis)
import SensitiveContentAnalysis
#endif

// MARK: - Sensitive Media Shield
/// The iMessage-style treatment for explicit media, driven by the
/// Show/Blur/Hide setting:
///  • blur — media is blurred under a veil with an eye-slash and a Show
///    button; revealing adds a small re-cover control.
///  • hide — media is replaced by a compact notice row.
///  • show — untouched.
struct SensitiveMediaShield: ViewModifier {
    /// Whether this media is explicit (Bluesky label or on-device analysis).
    let isSensitive: Bool

    @AppStorage(SensitiveMediaPolicy.storageKey)
    private var policyRaw: String = SensitiveMediaPolicy.defaultPolicy.rawValue
    @State private var revealed = false

    private var policy: SensitiveMediaPolicy { .stored(rawValue: policyRaw) }

    func body(content: Content) -> some View {
        if !isSensitive || policy == .show {
            content
        } else if revealed {
            content
                .overlay(alignment: .topLeading) {
                    // Re-cover control after an explicit reveal.
                    Button {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            revealed = false
                        }
                    } label: {
                        Image(systemName: "eye.slash.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel("Hide sensitive content again")
                }
        } else if policy == .hide {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                Text("Sensitive content hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(AtmoTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        } else {
            content
                .blur(radius: 28)
                .clipped()
                .overlay {
                    ZStack {
                        Color.black.opacity(0.22)
                        VStack(spacing: AtmoTheme.Spacing.sm) {
                            Image(systemName: "eye.slash.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                            Text("Sensitive content")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                            Button {
                                Haptics.tap()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    revealed = true
                                }
                            } label: {
                                Text("Show")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(.white.opacity(0.22), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .contentShape(Rectangle())
                // The veil owns taps — nothing underneath (viewer, thread
                // navigation) may fire through an unrevealed image.
                .onTapGesture {}
                .accessibilityLabel("Sensitive content, blurred. Double-tap Show to reveal.")
        }
    }
}

extension View {
    /// Applies the Show/Blur/Hide sensitive-media treatment.
    func sensitiveMediaShield(_ isSensitive: Bool) -> some View {
        modifier(SensitiveMediaShield(isSensitive: isSensitive))
    }
}

// MARK: - On-Device Screening (Apple SensitiveContentAnalysis)
/// The same framework iMessage uses for Sensitive Content Warning: fully
/// on-device nudity detection. It only activates when the person has
/// turned on Sensitive Content Warning in Settings → Privacy & Security —
/// otherwise `analysisPolicy` is `.disabled` and screening is skipped.
/// Verdicts are cached by URL so each image is analyzed once per session.
@MainActor
enum SensitiveImageScreener {

    private static var verdicts: [URL: Bool] = [:]

    static var isAvailable: Bool {
#if canImport(SensitiveContentAnalysis)
        return SCSensitivityAnalyzer().analysisPolicy != .disabled
#else
        return false
#endif
    }

    /// Whether the image at `url` contains sensitive content. Returns
    /// false whenever analysis can't run (feature off, fetch or decode
    /// failure) — the Bluesky labels remain the primary signal.
    static func isSensitive(imageAt url: URL) async -> Bool {
        if let cached = verdicts[url] { return cached }
#if canImport(SensitiveContentAnalysis)
        guard isAvailable else { return false }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let cgImage = Self.cgImage(from: data)
        else { return false }
        let analyzer = SCSensitivityAnalyzer()
        let flagged = (try? await analyzer.analyzeImage(cgImage))?.isSensitive ?? false
        verdicts[url] = flagged
        return flagged
#else
        return false
#endif
    }

    private static func cgImage(from data: Data) -> CGImage? {
#if os(iOS)
        return UIImage(data: data)?.cgImage
#elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
#else
        return nil
#endif
    }
}
