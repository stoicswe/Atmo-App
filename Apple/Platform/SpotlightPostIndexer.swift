#if canImport(CoreSpotlight)
import Foundation
import CoreSpotlight
import AppIntents
import AtmoCore

/// CoreSpotlight implementation of AtmoCore's `PostIndexing`: donates
/// bookmarked posts to the system Spotlight index so the user can find
/// them from system search. Available on iOS and macOS; watchOS has no
/// Spotlight and installs the no-op indexer instead.
struct SpotlightPostIndexer: PostIndexing {

    /// The domain identifier used for all Atmo bookmark Spotlight items.
    /// Scoped so we can batch-delete all bookmarks without affecting other
    /// app domains if we add more Spotlight features later.
    private static let spotlightDomain = "com.atmo.app.bookmarks"

    init() {}

    /// Donate an array of bookmarks to the CoreSpotlight index.
    /// Called whenever bookmarks are added or reloaded from storage.
    func index(_ bookmarks: [BookmarkedPost]) {
        guard !bookmarks.isEmpty else { return }

        let searchableItems: [CSSearchableItem] = bookmarks.map { bookmark in
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

            // Deep-link URL — the app opens this post's thread when tapped.
            // Uses the atmo:// scheme so we can distinguish app deep-links
            // from web URLs.
            let encodedURI = bookmark.uri.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bookmark.uri
            attrs.url = URL(string: "atmo://thread/\(encodedURI)")

            return CSSearchableItem(
                uniqueIdentifier: bookmark.uri,
                domainIdentifier: Self.spotlightDomain,
                attributeSet: attrs
            )
        }

        CSSearchableIndex.default().indexSearchableItems(searchableItems) { error in
            if let error {
                // Non-fatal: Spotlight indexing failure never affects app function
                print("[SpotlightPostIndexer] Spotlight indexing error: \(error.localizedDescription)")
            }
        }

        // The same bookmarks as App Entities, which is what Siri and the
        // semantic side of Spotlight search through. Only ever called with
        // ordinary bookmarks — the Vault has no path into this indexer.
        let entities = bookmarks.map(BookmarkEntity.init(bookmark:))
        Task {
            try? await CSSearchableIndex.default().indexAppEntities(entities)
        }
    }

    /// Remove specific bookmark URIs from the Spotlight index.
    /// Called whenever bookmarks are deleted.
    func removeFromIndex(uris: [String]) {
        guard !uris.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: uris) { error in
            if let error {
                print("[SpotlightPostIndexer] Spotlight deindex error: \(error.localizedDescription)")
            }
        }
        Task {
            try? await CSSearchableIndex.default().deleteAppEntities(identifiedBy: uris, ofType: BookmarkEntity.self)
        }
    }
}
#endif
