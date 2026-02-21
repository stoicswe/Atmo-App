import Foundation
import SwiftUI      // needed for IndexSet.remove(atOffsets:) and @Observable change tracking
import Observation
import CoreSpotlight

// MARK: - BookmarkedPost
// Lightweight Codable snapshot of a post stored locally and synced via iCloud KVS.
// Only stores what's needed to render the bookmark list row and navigate to the thread.
struct BookmarkedPost: Codable, Identifiable, Equatable {
    let id: String          // == uri, canonical identity
    let uri: String
    let cid: String
    let authorDID: String
    let authorHandle: String
    let authorDisplayName: String?
    let authorAvatarURLString: String?
    let text: String
    let indexedAt: Date
    let bookmarkedAt: Date

    var authorAvatarURL: URL? {
        authorAvatarURLString.flatMap { URL(string: $0) }
    }

    // Build from a live PostItem
    init(post: PostItem) {
        self.id             = post.uri
        self.uri            = post.uri
        self.cid            = post.cid
        self.authorDID      = post.authorDID
        self.authorHandle   = post.authorHandle
        self.authorDisplayName = post.authorDisplayName
        self.authorAvatarURLString = post.authorAvatarURL?.absoluteString
        self.text           = post.text
        self.indexedAt      = post.indexedAt
        self.bookmarkedAt   = Date()
    }
}

// MARK: - BookmarkStore
// @Observable singleton that persists bookmarks to both UserDefaults (local, always
// available) and iCloud Key-Value Storage (synced across devices when iCloud is active).
//
// Dual-write strategy:
//   • Every save writes to UserDefaults AND iCloud KVS.
//   • Load reads UserDefaults first (always available on launch), then merges any
//     iCloud-only entries that aren't already present locally. This ensures bookmarks
//     survive app relaunches even when iCloud is unavailable or hasn't synced yet.
//
// Usage:
//   BookmarkStore.shared.toggle(post)        // add or remove
//   BookmarkStore.shared.isBookmarked(post)  // check state
//   BookmarkStore.shared.bookmarks           // ordered array, newest first
@Observable
@MainActor
final class BookmarkStore {

    static let shared = BookmarkStore()

    // MARK: - State
    private(set) var bookmarks: [BookmarkedPost] = []

    // MARK: - Private
    // nonisolated(unsafe) lets us hold a reference to the KV store without
    // triggering a Swift 6 Sendable error when it's captured by the notification
    // observer Task below. All actual reads/writes go through @MainActor methods.
    nonisolated(unsafe) private let kvStore = NSUbiquitousKeyValueStore.default
    private let storeKey = "com.atmo.app.bookmarks"
    private var notificationTask: Task<Void, Never>? = nil

    private init() {
        load()
        startObservingRemoteChanges()
    }

    // MARK: - Public API

    func isBookmarked(_ post: PostItem) -> Bool {
        bookmarks.contains(where: { $0.uri == post.uri })
    }

    func toggle(_ post: PostItem) {
        if let idx = bookmarks.firstIndex(where: { $0.uri == post.uri }) {
            let removed = bookmarks[idx]
            bookmarks.remove(at: idx)
            deindexSpotlight(uris: [removed.uri])
        } else {
            let bookmark = BookmarkedPost(post: post)
            bookmarks.insert(bookmark, at: 0)
            indexSpotlight([bookmark])
        }
        persist()
    }

    func remove(at offsets: IndexSet) {
        let removed = offsets.map { bookmarks[$0] }
        bookmarks.remove(atOffsets: offsets)
        deindexSpotlight(uris: removed.map { $0.uri })
        persist()
    }

    // MARK: - Persistence

    /// Loads bookmarks from UserDefaults (primary) and merges in any iCloud-only
    /// entries. UserDefaults is always available immediately on launch, making it
    /// the reliable baseline. iCloud provides cross-device sync as a bonus.
    private func load() {
        let localBookmarks  = loadFromUserDefaults()
        let icloudBookmarks = loadFromKVStore()

        if localBookmarks.isEmpty && icloudBookmarks.isEmpty {
            bookmarks = []
            return
        }

        // Merge: start with local (already sorted newest-first), then append any
        // iCloud entries whose URIs aren't already present locally.
        let localURIs = Set(localBookmarks.map { $0.uri })
        let icloudOnly = icloudBookmarks.filter { !localURIs.contains($0.uri) }
        let merged = (localBookmarks + icloudOnly)
            .sorted { $0.bookmarkedAt > $1.bookmarkedAt }

        bookmarks = merged

        // If iCloud had entries that weren't in UserDefaults, backfill local storage
        if !icloudOnly.isEmpty {
            saveToUserDefaults(merged)
        }

        // Re-donate all bookmarks to Spotlight on every load so the index stays
        // fresh after app reinstalls, Spotlight reindexing, or iCloud merges.
        indexSpotlight(merged)
    }

    /// Writes bookmarks to both UserDefaults and iCloud KVS so they survive
    /// relaunches (UserDefaults) and sync across devices (iCloud KVS).
    private func persist() {
        saveToUserDefaults(bookmarks)
        saveToKVStore(bookmarks)
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

    // MARK: - iCloud KVS (secondary, cross-device sync)

    private func loadFromKVStore() -> [BookmarkedPost] {
        guard let data = kvStore.data(forKey: storeKey) else { return [] }
        return decode(data) ?? []
    }

    private func saveToKVStore(_ items: [BookmarkedPost]) {
        guard let data = encode(items) else { return }
        kvStore.set(data, forKey: storeKey)
        kvStore.synchronize()
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

    // MARK: - Spotlight Indexing

    /// The domain identifier used for all Atmo bookmark Spotlight items.
    /// Scoped so we can batch-delete all bookmarks without affecting other
    /// app domains if we add more Spotlight features later.
    private static let spotlightDomain = "com.atmo.app.bookmarks"

    /// Donate an array of bookmarks to the CoreSpotlight index.
    /// Called whenever bookmarks are added or reloaded from storage.
    private func indexSpotlight(_ items: [BookmarkedPost]) {
        guard !items.isEmpty else { return }

        let searchableItems: [CSSearchableItem] = items.map { bookmark in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)

            // Primary display text — what the user sees in Spotlight results
            attrs.title = bookmark.authorDisplayName ?? "@\(bookmark.authorHandle)"
            attrs.contentDescription = bookmark.text
            attrs.displayName = bookmark.authorDisplayName ?? "@\(bookmark.authorHandle)"

            // Metadata that Spotlight uses for ranking and display
            attrs.authorNames = [bookmark.authorDisplayName ?? bookmark.authorHandle]
            attrs.identifier = bookmark.uri

            // Timestamps
            attrs.contentCreationDate = bookmark.indexedAt
            attrs.contentModificationDate = bookmark.bookmarkedAt

            // Keywords so searches for "bookmarks" or the handle find this
            attrs.keywords = [
                "bookmark",
                "bluesky",
                bookmark.authorHandle,
                bookmark.authorDisplayName
            ].compactMap { $0 }

            // Deep-link URL — the app opens this post's thread when tapped
            // Uses the atmo:// scheme so we can distinguish app deep-links
            // from web URLs. Falls back to the bsky.app web URL so iOS can
            // also show a "Open in Safari" option.
            let encodedURI = bookmark.uri.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bookmark.uri
            attrs.url = URL(string: "atmo://thread/\(encodedURI)")

            // Thumbnail — if the post has an avatar URL we could fetch it here,
            // but async image loading in a sync context is complex. Spotlight
            // will display the app icon for items without a thumbnail image.

            return CSSearchableItem(
                uniqueIdentifier: bookmark.uri,
                domainIdentifier: Self.spotlightDomain,
                attributeSet: attrs
            )
        }

        CSSearchableIndex.default().indexSearchableItems(searchableItems) { error in
            if let error {
                // Non-fatal: Spotlight indexing failure never affects app function
                print("[BookmarkStore] Spotlight indexing error: \(error.localizedDescription)")
            }
        }
    }

    /// Remove specific bookmark URIs from the Spotlight index.
    /// Called whenever bookmarks are deleted.
    private func deindexSpotlight(uris: [String]) {
        guard !uris.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: uris) { error in
            if let error {
                print("[BookmarkStore] Spotlight deindex error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Remote Change Observation
    // NSUbiquitousKeyValueStore posts a notification when iCloud pushes a change
    // from another device. We dispatch the reload onto the next run-loop tick via
    // Task { @MainActor in } so it never fires during an active SwiftUI view update,
    // which would produce the "modifying state during view update" runtime warning.
    private func startObservingRemoteChanges() {
        let key = storeKey
        notificationTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(
                named: NSUbiquitousKeyValueStore.didChangeExternallyNotification
            )
            for await notification in stream {
                let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
                guard changedKeys?.contains(key) == true else { continue }
                // Hop to MainActor for the state mutation, scheduled on the next
                // run-loop cycle so it doesn't overlap with an in-progress view update.
                Task { @MainActor [weak self] in
                    self?.load()
                }
            }
        }
    }
}
