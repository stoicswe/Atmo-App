import Foundation
import ATProtoKit
import Observation

// MARK: - Custom Feed Item
/// One saved feed generator from the user's Bluesky preferences — the app
/// doesn't create or manage feeds, it just lets the user switch to ones
/// they saved in any client.
public struct CustomFeedItem: Identifiable, Hashable, Sendable {
    public let id: String   // == uri
    public let uri: String
    public let displayName: String
    public let avatarURL: URL?
    public let isPinned: Bool

    public init(uri: String, displayName: String, avatarURL: URL?, isPinned: Bool) {
        self.id = uri
        self.uri = uri
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.isPinned = isPinned
    }
}

// MARK: - Saved Feeds Store
/// Session cache of the user's saved feed generators, split into pinned
/// (quick-switch, shown under Home) and the rest. Loaded once per session
/// and on demand.
@Observable
@MainActor
public final class SavedFeedsStore {

    public static let shared = SavedFeedsStore()

    public private(set) var pinned: [CustomFeedItem] = []
    public private(set) var unpinned: [CustomFeedItem] = []
    public private(set) var hasLoadedOnce = false

    private init() {}

    /// Fetches saved-feed preferences and resolves each generator's
    /// display info. Silent on failure — the drawer just shows no feeds.
    ///
    /// No in-flight guard, deliberately: callers run this from
    /// `.task(id: sessionDID)`, which CANCELS the launch-time attempt the
    /// moment the session identity lands and immediately starts the real
    /// one. A busy-flag made that replacement bail while the cancelled
    /// attempt unwound — leaving the store empty forever. A cancelled
    /// attempt throws before writing, so the latest attempt's writes win.
    public func load(service: ATProtoService) async {
        guard let kit = service.atProtoKit else { return }

        do {
            let output = try await kit.getPreferences()
            var saved: [AppBskyLexicon.Actor.SavedFeed] = []
            for preference in output.preferences {
                if case .savedFeedsVersion2(let definition) = preference {
                    saved = definition.items
                }
            }
            // Feed generators only — lists and the built-in following
            // timeline aren't switchable feeds here.
            let refs = saved
                .filter { $0.feedType == .feed }
                .map { SavedFeedRef(uri: $0.value, isPinned: $0.isPinned) }
            guard !refs.isEmpty else {
                pinned = []
                unpinned = []
                hasLoadedOnce = true
                return
            }

            let generators = try await kit.getFeedGenerators(by: refs.map(\.uri)).feeds
            var names: [String: String] = [:]
            var avatars: [String: URL] = [:]
            for generator in generators {
                names[generator.feedURI] = generator.displayName
                if let avatar = generator.avatarImageURL {
                    avatars[generator.feedURI] = avatar
                }
            }

            let merged = Self.merge(refs: refs, names: names, avatars: avatars)
            pinned = merged.pinned
            unpinned = merged.unpinned
            hasLoadedOnce = true
        } catch {
            // Background fetch — not worth surfacing (cancellation of a
            // superseded attempt lands here too).
        }
    }

    /// Pure merge core (unit-tested): joins saved-feed refs with resolved
    /// generator info, preserving the preference order; refs whose
    /// generator can't be resolved (deleted feeds) are dropped.
    public struct SavedFeedRef: Sendable, Equatable {
        public let uri: String
        public let isPinned: Bool
        public init(uri: String, isPinned: Bool) {
            self.uri = uri
            self.isPinned = isPinned
        }
    }

    nonisolated public static func merge(
        refs: [SavedFeedRef],
        names: [String: String],
        avatars: [String: URL]
    ) -> (pinned: [CustomFeedItem], unpinned: [CustomFeedItem]) {
        var pinned: [CustomFeedItem] = []
        var unpinned: [CustomFeedItem] = []
        for ref in refs {
            guard let name = names[ref.uri] else { continue }
            let item = CustomFeedItem(
                uri: ref.uri,
                displayName: name,
                avatarURL: avatars[ref.uri],
                isPinned: ref.isPinned
            )
            if ref.isPinned {
                pinned.append(item)
            } else {
                unpinned.append(item)
            }
        }
        return (pinned, unpinned)
    }
}
