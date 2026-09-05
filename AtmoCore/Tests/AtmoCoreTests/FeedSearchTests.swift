import Foundation
import Testing
@testable import AtmoCore

/// Covers the Feeds search category's pure parts: the row subtitle and
/// the de-duplicating page append behind infinite scroll.
struct FeedSearchTests {

    private func feed(_ uri: String, likes: Int = 0) -> FeedSearchResult {
        FeedSearchResult(
            uri: uri, displayName: "Feed \(uri)", description: nil, avatarURL: nil,
            creatorHandle: "maker.bsky.social", creatorDisplayName: "Maker", likeCount: likes
        )
    }

    @Test func subtitleNamesCreatorAndLikes() {
        #expect(FeedSearchResult.subtitle(creatorHandle: "alice.bsky.social", likeCount: 0) == "by @alice.bsky.social")
        #expect(FeedSearchResult.subtitle(creatorHandle: "alice.bsky.social", likeCount: 1) == "by @alice.bsky.social · 1 like")
        #expect(FeedSearchResult.subtitle(creatorHandle: "alice.bsky.social", likeCount: 12_400) == "by @alice.bsky.social · 12K likes")
        #expect(feed("at://f/1", likes: 3).subtitle == "by @maker.bsky.social · 3 likes")
    }

    @Test func appendingDropsDuplicatesAndKeepsOrder() {
        let first = [feed("at://f/1"), feed("at://f/2")]
        let page = [feed("at://f/2"), feed("at://f/3"), feed("at://f/1"), feed("at://f/4")]
        let merged = FeedSearchResult.appending(page, to: first)
        #expect(merged.map(\.uri) == ["at://f/1", "at://f/2", "at://f/3", "at://f/4"])
        #expect(FeedSearchResult.appending([], to: first).map(\.uri) == ["at://f/1", "at://f/2"])
    }

    @Test func sortFollowsTopAndLatest() {
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = FeedSearchResult(uri: "at://f/a", displayName: "A", description: nil, avatarURL: nil,
                                 creatorHandle: "x", creatorDisplayName: nil, likeCount: 50, indexedAt: base)
        let b = FeedSearchResult(uri: "at://f/b", displayName: "B", description: nil, avatarURL: nil,
                                 creatorHandle: "x", creatorDisplayName: nil, likeCount: 500, indexedAt: base.addingTimeInterval(-day))
        let c = FeedSearchResult(uri: "at://f/c", displayName: "C", description: nil, avatarURL: nil,
                                 creatorHandle: "x", creatorDisplayName: nil, likeCount: 50, indexedAt: base.addingTimeInterval(day))
        let served = [a, b, c]
        #expect(FeedSearchResult.sorted(served, by: .top).map(\.uri) == ["at://f/b", "at://f/a", "at://f/c"])   // ties keep server order
        #expect(FeedSearchResult.sorted(served, by: .latest).map(\.uri) == ["at://f/c", "at://f/a", "at://f/b"])
        #expect(FeedSearchResult.sorted([], by: .top).isEmpty)
    }

    @Test func opensAsCustomFeed() {
        let custom = feed("at://f/9").asCustomFeed
        #expect(custom.uri == "at://f/9")
        #expect(custom.displayName == "Feed at://f/9")
        #expect(!custom.isPinned)
    }

    @Test func feedsIsASearchCategory() {
        #expect(SearchCategory.allCases.contains(.feeds))
        #expect(SearchCategory.feeds.rawValue == "Feeds")
    }
}
