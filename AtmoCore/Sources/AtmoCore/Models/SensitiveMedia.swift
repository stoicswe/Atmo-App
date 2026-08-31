import Foundation

// MARK: - Sensitive Media Policy
/// How the app treats media labeled (or detected) as explicit:
/// blur behind a reveal (default, the iMessage-style treatment), hide it
/// outright, or show it untouched.
public enum SensitiveMediaPolicy: String, CaseIterable, Identifiable, Sendable {
    case show
    case blur
    case hide

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .show: return "Show"
        case .blur: return "Blur"
        case .hide: return "Hide"
        }
    }

    /// UserDefaults/AppStorage key.
    public static let storageKey = "atmo.media.sensitivePolicy"
    /// Safe default: covered, one tap to reveal.
    public static let defaultPolicy: SensitiveMediaPolicy = .blur

    public static func stored(rawValue: String?) -> SensitiveMediaPolicy {
        rawValue.flatMap(SensitiveMediaPolicy.init(rawValue:)) ?? defaultPolicy
    }
}

extension PostItem {
    /// Label values (Bluesky's global moderation labels + self-labels)
    /// that mark a post's media as adult or graphic content. Public so UI
    /// layers can apply the same check to labels on embedded records
    /// (quoted posts) that never become a PostItem.
    public static let sensitiveMediaLabelValues: Set<String> = [
        "porn", "sexual", "nudity", "graphic-media", "gore",
    ]

    /// Whether this post's media is labeled explicit/graphic — by the
    /// author's self-label or a subscribed labeler.
    public var hasSensitiveMediaLabel: Bool {
        contentLabels.contains { Self.sensitiveMediaLabelValues.contains($0) }
    }
}
