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
    /// A subscribe / unsubscribe / pin write is in flight.
    public private(set) var isUpdating = false
    public private(set) var lastError: Error? = nil

    private init() {}

    public func isSubscribed(uri: String) -> Bool {
        pinned.contains { $0.uri == uri } || unpinned.contains { $0.uri == uri }
    }

    public func isPinned(uri: String) -> Bool {
        pinned.contains { $0.uri == uri }
    }

    // MARK: - Writes (saved feeds live in the account's preferences)

    /// Adds a feed to the account's saved feeds, pinned or not. Idempotent:
    /// re-subscribing only updates the pin.
    public func subscribe(_ feed: CustomFeedItem, pinned: Bool, service: ATProtoService) async {
        await mutate(service: service) { Self.subscribing($0, uri: feed.uri, pinned: pinned) }
    }

    public func unsubscribe(uri: String, service: ATProtoService) async {
        await mutate(service: service) { Self.unsubscribing($0, uri: uri) }
    }

    public func setPinned(_ pinned: Bool, uri: String, service: ATProtoService) async {
        await mutate(service: service) { Self.settingPinned($0, uri: uri, pinned: pinned) }
    }

    /// Read-modify-write of the `savedFeedsPrefV2` entry in the account's
    /// preferences, then a reload so the drawer and sidebar follow.
    private func mutate(
        service: ATProtoService,
        _ transform: ([AppBskyLexicon.Actor.SavedFeed]) -> [AppBskyLexicon.Actor.SavedFeed]
    ) async {
        guard let kit = service.atProtoKit, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            var preferences = try await kit.getPreferences().preferences
            var items: [AppBskyLexicon.Actor.SavedFeed] = []
            var index: Int? = nil
            for (i, preference) in preferences.enumerated() {
                if case .savedFeedsVersion2(let definition) = preference {
                    items = definition.items
                    index = i
                }
            }
            let updated = AppBskyLexicon.Actor.PreferenceUnion.savedFeedsVersion2(
                AppBskyLexicon.Actor.SavedFeedPreferencesVersion2Definition(items: transform(items))
            )
            if let index {
                preferences[index] = updated
            } else {
                preferences.append(updated)
            }
            try await kit.putPreferences(preferences: preferences)
            lastError = nil
            await load(service: service)
        } catch {
            lastError = error
        }
    }

    // MARK: - Pure list transforms (unit-tested)

    nonisolated public static func subscribing(
        _ items: [AppBskyLexicon.Actor.SavedFeed], uri: String, pinned: Bool
    ) -> [AppBskyLexicon.Actor.SavedFeed] {
        if items.contains(where: { $0.value == uri }) {
            return settingPinned(items, uri: uri, pinned: pinned)
        }
        return items + [AppBskyLexicon.Actor.SavedFeed(
            feedID: newFeedID(), feedType: .feed, value: uri, isPinned: pinned
        )]
    }

    nonisolated public static func unsubscribing(
        _ items: [AppBskyLexicon.Actor.SavedFeed], uri: String
    ) -> [AppBskyLexicon.Actor.SavedFeed] {
        items.filter { $0.value != uri }
    }

    nonisolated public static func settingPinned(
        _ items: [AppBskyLexicon.Actor.SavedFeed], uri: String, pinned: Bool
    ) -> [AppBskyLexicon.Actor.SavedFeed] {
        items.map { item in
            guard item.value == uri else { return item }
            return AppBskyLexicon.Actor.SavedFeed(
                feedID: item.feedID, feedType: item.feedType, value: item.value, isPinned: pinned
            )
        }
    }

    /// Saved-feed entries carry an opaque id; a fresh one per addition.
    nonisolated static func newFeedID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

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
