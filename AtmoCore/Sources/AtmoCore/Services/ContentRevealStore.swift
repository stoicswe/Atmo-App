import Foundation
import Observation

// MARK: - Content Reveal Store
/// Session memory of what the person has chosen to see past a content
/// veil — a mature-content post, an explicit image, video, or GIF.
///
/// Keyed by a stable string (the post URI for whole-post covers, the
/// media URL for media covers) so a reveal made in one place carries
/// everywhere the same content appears: feed → thread, quote card,
/// search results, and back. Re-covering removes the key again.
///
/// Deliberately in-memory only: every launch starts covered again, the
/// same way the official client behaves.
@MainActor
@Observable
public final class ContentRevealStore {
    public static let shared = ContentRevealStore()

    public private(set) var revealed: Set<String> = []

    public init() {}

    public func isRevealed(_ key: String) -> Bool {
        revealed.contains(key)
    }

    public func setRevealed(_ key: String, _ value: Bool) {
        if value {
            revealed.insert(key)
        } else {
            revealed.remove(key)
        }
    }

    public func reset() {
        revealed.removeAll()
    }
}
