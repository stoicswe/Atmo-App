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
    /// Stable identity for the reveal — the media URL, or the post URI —
    /// so a Show here carries into every other view of the same media
    /// (feed → thread, quote, search). Nil keeps the reveal local.
    var key: String? = nil

    /// The whole post is already under MatureContentShield — that veil
    /// covers this media too, so no second blur is stacked inside it, and
    /// the post's single Show reveals everything.
    @Environment(\.coveredByPostShield) private var coveredByPost

    @AppStorage(SensitiveMediaPolicy.storageKey)
    private var policyRaw: String = SensitiveMediaPolicy.defaultPolicy.rawValue
    @AppStorage(ContentControlsMode.storageKey)
    private var modeRaw: String = ContentControlsMode.blur.rawValue
    /// Fallback for keyless uses; keyed reveals live in ContentRevealStore.
    @State private var localRevealed = false

    private var revealed: Bool {
        if let key { return ContentRevealStore.shared.isRevealed(key) }
        return localRevealed
    }

    private func setRevealed(_ value: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if let key {
                ContentRevealStore.shared.setRevealed(key, value)
            } else {
                localRevealed = value
            }
        }
    }

    /// The stored preference — the master content-controls mode wins when
    /// uniform, Custom falls back to the media-specific setting — then
    /// overridden to Hide for managed minors (Family controls lock).
    private var policy: SensitiveMediaPolicy {
        let mode = ContentControlsMode(rawValue: modeRaw) ?? .blur
        let stored = mode.uniformPolicy ?? .stored(rawValue: policyRaw)
        return ParentalControlsStore.shared.effectiveSensitiveMediaPolicy(stored: stored)
    }

    func body(content: Content) -> some View {
        if !isSensitive || policy == .show || coveredByPost {
            content
        } else if revealed {
            content
                .overlay(alignment: .topLeading) {
                    // Re-cover control after an explicit reveal.
                    Button {
                        Haptics.tap()
                        setRevealed(false)
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
                                setRevealed(true)
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
    /// Applies the Show/Blur/Hide sensitive-media treatment. Pass a stable
    /// `key` (media URL or post URI) so a reveal follows the content into
    /// other views instead of resetting per cell.
    func sensitiveMediaShield(_ isSensitive: Bool, key: String? = nil) -> some View {
        modifier(SensitiveMediaShield(isSensitive: isSensitive, key: key))
    }
}

// MARK: - Post-level cover
/// Set by MatureContentShield on a post it is treating (veiled, or
/// explicitly revealed by the person). Media inside reads it to skip its
/// own veil: one blur per post, one Show to reveal, never blur on blur.
private struct CoveredByPostShieldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var coveredByPostShield: Bool {
        get { self[CoveredByPostShieldKey.self] }
        set { self[CoveredByPostShieldKey.self] = newValue }
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

// MARK: - Mature Content Shield
/// Whole-post treatment for the Age Ratings content categories: Hide
/// replaces the post with a compact notice; Blur veils it behind a
/// category-named reveal. Detection (text wordlists + Bluesky labels) is
/// cached per post URI; policy resolution stays live so Settings changes
/// apply immediately.
@MainActor
enum MatureCheckCache {
    private static var cache: [String: Set<MatureContentCategory>] = [:]

    static func categories(text: String, labels: [String], uri: String) -> Set<MatureContentCategory> {
        if let cached = cache[uri] { return cached }
        let matched = MatureContentScreener.categories(text: text, labels: labels)
        if cache.count > 4000 { cache.removeAll() }
        cache[uri] = matched
        return matched
    }
}

struct MatureContentShield: ViewModifier {
    let text: String
    let labels: [String]
    let uri: String

    /// Session-wide by post URI: revealing the post in the feed keeps it
    /// revealed when it's opened, quoted, or found again.
    private var revealed: Bool { ContentRevealStore.shared.isRevealed(uri) }

    private func setRevealed(_ value: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            ContentRevealStore.shared.setRevealed(uri, value)
        }
    }

    func body(content: Content) -> some View {
        let treatment = ParentalControlsStore.shared.matureTreatment(
            categories: MatureCheckCache.categories(text: text, labels: labels, uri: uri)
        )
        if treatment.policy == .show || treatment.category == nil {
            content
        } else if revealed {
            // The person chose to see this post: its media shows too,
            // rather than asking for a second reveal inside the first.
            content
                .environment(\.coveredByPostShield, true)
                .overlay(alignment: .topTrailing) {
                    Button {
                        Haptics.tap()
                        setRevealed(false)
                    } label: {
                        Image(systemName: "eye.slash.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel("Cover this post again")
                }
        } else if treatment.policy == .hide {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                Image(systemName: treatment.category?.iconName ?? "eye.slash")
                    .foregroundStyle(.secondary)
                Text("Hidden — \(treatment.category?.displayName ?? "mature content")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(AtmoTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
            .padding(.vertical, AtmoTheme.Spacing.xs)
        } else {
            // Media inside drops its own veil — this one covers the lot.
            content
                .environment(\.coveredByPostShield, true)
                .blur(radius: 22)
                .clipped()
                .overlay {
                    ZStack {
                        Color.black.opacity(0.2)
                        VStack(spacing: AtmoTheme.Spacing.sm) {
                            Image(systemName: treatment.category?.iconName ?? "eye.slash")
                                .font(.title3)
                                .foregroundStyle(.white)
                            Text(treatment.category?.displayName ?? "Mature content")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                            Button {
                                Haptics.tap()
                                setRevealed(true)
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
                .onTapGesture {}
                .accessibilityLabel("\(treatment.category?.displayName ?? "Mature content"), covered. Double-tap Show to reveal.")
        }
    }
}

extension View {
    /// Applies the per-category mature-content treatment to a whole post.
    func matureContentShield(text: String, labels: [String], uri: String) -> some View {
        modifier(MatureContentShield(text: text, labels: labels, uri: uri))
    }
}
