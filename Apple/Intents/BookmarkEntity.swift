import AppIntents
import CoreSpotlight
import AtmoCore

// MARK: - Bookmark Entity
/// A bookmarked post as Siri, Shortcuts, and Spotlight see it. Built only
/// from BookmarkStore — the Vault has its own store and is never exposed
/// here, so nothing private reaches the system index or Siri.
struct BookmarkEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Bookmarked Post"
    static var defaultQuery = BookmarkQuery()

    /// The post's AT URI.
    let id: String
    let authorName: String
    let authorHandle: String
    let text: String
    let bookmarkedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(authorName)",
            subtitle: "\(text.isEmpty ? "@" + authorHandle : text)"
        )
    }

    /// Spotlight attributes for the entity index (the semantic /
    /// Siri-searchable side; the classic searchable item is donated by
    /// SpotlightPostIndexer alongside).
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.displayName = authorName
        attributes.title = authorName
        attributes.contentDescription = text
        attributes.authorNames = [authorName]
        attributes.keywords = ["bookmark", "bluesky", authorHandle]
        attributes.contentCreationDate = bookmarkedAt
        return attributes
    }

    init(bookmark: BookmarkedPost) {
        self.id = bookmark.uri
        self.authorName = bookmark.authorDisplayName ?? "@\(bookmark.authorHandle)"
        self.authorHandle = bookmark.authorHandle
        self.text = bookmark.text
        self.bookmarkedAt = bookmark.bookmarkedAt
    }
}

// MARK: - Bookmark Query
/// Resolves and searches bookmarks. Reads BookmarkStore only — the
/// Vault's contents are never candidates.
struct BookmarkQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [BookmarkEntity] {
        let wanted = Set(identifiers)
        return BookmarkStore.shared.bookmarks
            .filter { wanted.contains($0.uri) }
            .map(BookmarkEntity.init(bookmark:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [BookmarkEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return BookmarkStore.shared.bookmarks
            .filter {
                $0.text.localizedCaseInsensitiveContains(needle)
                    || $0.authorHandle.localizedCaseInsensitiveContains(needle)
                    || ($0.authorDisplayName?.localizedCaseInsensitiveContains(needle) ?? false)
            }
            .prefix(25)
            .map(BookmarkEntity.init(bookmark:))
    }

    @MainActor
    func suggestedEntities() async throws -> [BookmarkEntity] {
        BookmarkStore.shared.bookmarks.prefix(10).map(BookmarkEntity.init(bookmark:))
    }
}

// MARK: - App Section Entity
/// The sections an intent may open. The Vault is deliberately absent: it
/// only opens from Bookmarks after owner verification.
enum AppSection: String, AppEnum {
    case home, search, activity, messages, bookmarks, liked, drafts, settings

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Section"
    static var caseDisplayRepresentations: [AppSection: DisplayRepresentation] = [
        .home: "Home",
        .search: "Search",
        .activity: "Activity",
        .messages: "Messages",
        .bookmarks: "Bookmarks",
        .liked: "Liked",
        .drafts: "Drafts",
        .settings: "Settings",
    ]

    var sidebarItem: SidebarItem {
        switch self {
        case .home:      return .timeline
        case .search:    return .search
        case .activity:  return .notifications
        case .messages:  return .messages
        case .bookmarks: return .bookmarks
        case .liked:     return .liked
        case .drafts:    return .drafts
        case .settings:  return .settings
        }
    }
}
