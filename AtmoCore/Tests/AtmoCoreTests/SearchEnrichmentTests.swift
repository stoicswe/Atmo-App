import Foundation
import Testing
@testable import AtmoCore

/// Covers the invisible search-enrichment machinery: trend feed-link
/// conversion, contextual query variants, and the URI-deduplicated merge.
struct SearchEnrichmentTests {

    // MARK: - Trend link → feed at-uri

    @Test func trendLinkConvertsToFeedURI() {
        let uri = TrendingTopicItem.feedURI(
            fromLink: "/profile/did:plc:qrz3lhbyuxbeilrc6nekdqme/feed/d310c577b343"
        )
        #expect(uri == "at://did:plc:qrz3lhbyuxbeilrc6nekdqme/app.bsky.feed.generator/d310c577b343")
    }

    @Test func nonFeedLinksAreRejected() {
        #expect(TrendingTopicItem.feedURI(fromLink: nil) == nil)
        #expect(TrendingTopicItem.feedURI(fromLink: "/search?q=topic") == nil)
        #expect(TrendingTopicItem.feedURI(fromLink: "/profile/alice.bsky.social/feed/key") == nil)
        #expect(TrendingTopicItem.feedURI(fromLink: "/profile/did:plc:abc/lists/key") == nil)
        #expect(TrendingTopicItem.feedURI(fromLink: "/profile/did:plc:abc/feed/") == nil)
    }

    // MARK: - Query variants

    @Test func variantsCoverQuotedPhraseKeywordCoreAndContext() {
        let variants = SearchQueryExpansion.variants(
            for: "US Open tennis underway",
            description: "Fans debate matches, McEnroe's remarks, and Alcaraz's Nike ad with Travis Scott."
        )
        #expect(variants.contains("\"US Open tennis underway\""))
        // "underway" is headline filler — the keyword core drops it.
        #expect(variants.contains("US Open tennis"))
        // Description proper-noun run, anchored to the query's own
        // leading proper nouns.
        #expect(variants.contains("US Open Travis Scott"))
        // The base query itself is never repeated.
        #expect(!variants.contains("US Open tennis underway"))
        #expect(variants.count <= 4)
    }

    @Test func singleWordQueryGetsNoQuotedVariant() {
        let variants = SearchQueryExpansion.variants(for: "Bluesky")
        #expect(!variants.contains("\"Bluesky\""))
    }

    @Test func properNounRunsRequireTwoCapitalizedWords() {
        let runs = SearchQueryExpansion.properNounRuns(
            in: "Supreme Court weighs whether White House ballroom construction may proceed."
        )
        #expect(runs == ["Supreme Court", "White House"])
    }

    @Test func emptyQueryYieldsNothing() {
        #expect(SearchQueryExpansion.variants(for: "   ").isEmpty)
    }

    // MARK: - Merge

    @Test func mergeKeepsPrimaryOrderDedupsAndCaps() {
        let primary = [PostItem(testURI: "a"), PostItem(testURI: "b")]
        let extras = [
            PostItem(testURI: "b"),   // duplicate — dropped
            PostItem(testURI: "c"),
            PostItem(testURI: "d")
        ]
        let merged = SearchViewModel.mergedUnique(primary: primary, extras: extras, cap: 3)
        #expect(merged.map(\.uri) == ["a", "b", "c"])
    }

    @Test func mergeWithEmptyPrimaryIsJustDedupedExtras() {
        let extras = [PostItem(testURI: "x"), PostItem(testURI: "x"), PostItem(testURI: "y")]
        let merged = SearchViewModel.mergedUnique(primary: [], extras: extras, cap: 80)
        #expect(merged.map(\.uri) == ["x", "y"])
    }
}
