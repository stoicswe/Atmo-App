import Foundation
import Observation

// @Observable singleton that persists bookmarks to both UserDefaults (local,
// always available) and the platform's synced key-value store (iCloud KVS on
// Apple platforms; local-only elsewhere).
//
// Dual-write strategy:
//   • Every save writes to UserDefaults AND the synced store.
//   • Load reads UserDefaults first (always available on launch), then merges
//     any synced-only entries that aren't already present locally. This
//     ensures bookmarks survive app relaunches even when sync is unavailable
//     or hasn't caught up yet.
//
// Bookmarks are also donated to the platform's search index
// (`Atmo.platform.postIndexer` — Spotlight on iOS/macOS) on every change.
//
// Usage:
//   BookmarkStore.shared.toggle(post)        // add or remove
//   BookmarkStore.shared.isBookmarked(post)  // check state
//   BookmarkStore.shared.bookmarks           // ordered array, newest first
@Observable
@MainActor
public final class BookmarkStore {

    public static let shared = BookmarkStore()

    // MARK: - State
    public private(set) var bookmarks: [BookmarkedPost] = []

    // MARK: - Private
    private let syncedStore = Atmo.platform.syncedKeyValue
    private let indexer = Atmo.platform.postIndexer
    private let storeKey = "com.atmo.app.bookmarks"
    private var externalChangeTask: Task<Void, Never>? = nil

    private init() {
        load()
        startObservingRemoteChanges()
    }

    // MARK: - Public API

    public func isBookmarked(_ post: PostItem) -> Bool {
        bookmarks.contains(where: { $0.uri == post.uri })
    }

    public func toggle(_ post: PostItem) {
        if let idx = bookmarks.firstIndex(where: { $0.uri == post.uri }) {
            let removed = bookmarks[idx]
            bookmarks.remove(at: idx)
            indexer.removeFromIndex(uris: [removed.uri])
        } else {
            let bookmark = BookmarkedPost(post: post)
            bookmarks.insert(bookmark, at: 0)
            indexer.index([bookmark])
        }
        persist()
    }

    public func remove(at offsets: IndexSet) {
        let removed = offsets.map { bookmarks[$0] }
        // Highest index first so earlier removals don't shift later ones.
        // (SwiftUI's remove(atOffsets:) sugar is not available on Linux.)
        for index in offsets.sorted(by: >) {
            bookmarks.remove(at: index)
        }
        indexer.removeFromIndex(uris: removed.map { $0.uri })
        persist()
    }

    // MARK: - Persistence

    /// Loads bookmarks from UserDefaults (primary) and merges in any
    /// synced-only entries. UserDefaults is always available immediately on
    /// launch, making it the reliable baseline; the synced store provides
    /// cross-device sync as a bonus.
    private func load() {
        let localBookmarks  = loadFromUserDefaults()
        let syncedBookmarks = loadFromSyncedStore()

        if localBookmarks.isEmpty && syncedBookmarks.isEmpty {
            bookmarks = []
            return
        }

        // Merge: start with local (already sorted newest-first), then append
        // any synced entries whose URIs aren't already present locally.
        let localURIs = Set(localBookmarks.map { $0.uri })
        let syncedOnly = syncedBookmarks.filter { !localURIs.contains($0.uri) }
        let merged = (localBookmarks + syncedOnly)
            .sorted { $0.bookmarkedAt > $1.bookmarkedAt }

        bookmarks = merged

        // If sync had entries that weren't in UserDefaults, backfill local storage
        if !syncedOnly.isEmpty {
            saveToUserDefaults(merged)
        }

        // Re-donate all bookmarks to the search index on every load so it
        // stays fresh after reinstalls, reindexing, or sync merges.
        indexer.index(merged)
    }

    /// Writes bookmarks to both UserDefaults and the synced store so they
    /// survive relaunches (UserDefaults) and sync across devices.
    private func persist() {
        saveToUserDefaults(bookmarks)
        saveToSyncedStore(bookmarks)
    }

    // MARK: - UserDefaults (local, primary)

    private func loadFromUserDefaults() -> [BookmarkedPost] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [] }
        return decode(data) ?? []
    }

    private func saveToUserDefaults(_ items: [BookmarkedPost]) {
        guard let data = encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    // MARK: - Synced store (secondary, cross-device sync)

    private func loadFromSyncedStore() -> [BookmarkedPost] {
        guard let data = syncedStore.data(forKey: storeKey) else { return [] }
        return decode(data) ?? []
    }

    private func saveToSyncedStore(_ items: [BookmarkedPost]) {
        guard let data = encode(items) else { return }
        syncedStore.set(data, forKey: storeKey)
        syncedStore.synchronize()
    }

    // MARK: - Codec helpers

    private func encode(_ items: [BookmarkedPost]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(items)
    }

    private func decode(_ data: Data) -> [BookmarkedPost]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([BookmarkedPost].self, from: data)
    }

    // MARK: - Remote Change Observation
    // The synced store emits a batch of changed keys when another device
    // pushes a change. The reload is dispatched onto the next run-loop tick
    // via Task { @MainActor in } so it never fires during an active view
    // update, which would produce the "modifying state during view update"
    // runtime warning.
    private func startObservingRemoteChanges() {
        let key = storeKey
        let changes = syncedStore.externalChanges()
        externalChangeTask = Task { [weak self] in
            for await changedKeys in changes {
                guard changedKeys.contains(key) else { continue }
                Task { @MainActor [weak self] in
                    self?.load()
                }
            }
        }
    }
}
