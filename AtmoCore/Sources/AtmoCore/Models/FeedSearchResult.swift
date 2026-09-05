import Foundation
import ATProtoKit

// MARK: - Feed Search Result
/// A public feed generator found by name (`getPopularFeedGenerators`
/// with a query): enough to judge it in a list — name, who made it, how
/// many people like it, and its description — and to open it.
public struct FeedSearchResult: Identifiable, Hashable, Sendable {
    public let id: String   // == uri
    public let uri: String
    public let displayName: String
    public let description: String?
    public let avatarURL: URL?
    public let creatorHandle: String
    public let creatorDisplayName: String?
    public let likeCount: Int
    /// When the generator was indexed — "Latest" ordering.
    public let indexedAt: Date

    public init(
        uri: String,
        displayName: String,
        description: String?,
        avatarURL: URL?,
        creatorHandle: String,
        creatorDisplayName: String?,
        likeCount: Int,
        indexedAt: Date = .distantPast
    ) {
        self.id = uri
        self.uri = uri
        self.displayName = displayName
        self.description = description
        self.avatarURL = avatarURL
        self.creatorHandle = creatorHandle
        self.creatorDisplayName = creatorDisplayName
        self.likeCount = likeCount
        self.indexedAt = indexedAt
    }

    public init(generator: AppBskyLexicon.Feed.GeneratorViewDefinition) {
        self.init(
            uri: generator.feedURI,
            displayName: generator.displayName,
            description: generator.description,
            avatarURL: generator.avatarImageURL,
            creatorHandle: generator.creator.actorHandle,
            creatorDisplayName: generator.creator.displayName,
            likeCount: generator.likeCount ?? 0,
            indexedAt: generator.indexedAt
        )
    }

    /// Orders results under the search page's Top/Latest switch: Top by
    /// likes (ties keep the server's popularity order), Latest by newest
    /// indexed. Stable, so paging in more results never shuffles the
    /// ones already on screen among equals. Pure; unit-tested.
    nonisolated public static func sorted(
        _ feeds: [FeedSearchResult],
        by sort: SearchViewModel.SearchSort
    ) -> [FeedSearchResult] {
        switch sort {
        case .top:
            return feeds.enumerated().sorted { a, b in
                if a.element.likeCount != b.element.likeCount {
                    return a.element.likeCount > b.element.likeCount
                }
                return a.offset < b.offset
            }.map(\.element)
        case .latest:
            return feeds.enumerated().sorted { a, b in
                if a.element.indexedAt != b.element.indexedAt {
                    return a.element.indexedAt > b.element.indexedAt
                }
                return a.offset < b.offset
            }.map(\.element)
        }
    }

    /// "by @handle · 12K likes" — the row's second line.
    public var subtitle: String {
        Self.subtitle(creatorHandle: creatorHandle, likeCount: likeCount)
    }

    /// What the app switches to when the result is opened.
    public var asCustomFeed: CustomFeedItem {
        CustomFeedItem(uri: uri, displayName: displayName, avatarURL: avatarURL, isPinned: false)
    }

    nonisolated public static func subtitle(creatorHandle: String, likeCount: Int) -> String {
        var parts = ["by @\(creatorHandle)"]
        if likeCount > 0 {
            let count = likeCount.formatted(.number.notation(.compactName))
            parts.append(likeCount == 1 ? "1 like" : "\(count) likes")
        }
        return parts.joined(separator: " · ")
    }

    /// Appends `page` to `existing`, dropping feeds already listed —
    /// popularity-ranked pages can overlap. Pure; unit-tested.
    nonisolated public static func appending(_ page: [FeedSearchResult], to existing: [FeedSearchResult]) -> [FeedSearchResult] {
        var seen = Set(existing.map(\.uri))
        var result = existing
        for feed in page where seen.insert(feed.uri).inserted {
            result.append(feed)
        }
        return result
    }
}
