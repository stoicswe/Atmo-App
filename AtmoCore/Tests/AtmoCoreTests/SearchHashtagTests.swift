import Foundation
import Testing
@testable import AtmoCore

/// Covers the hashtag extraction feeding the search results' hashtag
/// category from loaded post pages.
struct SearchHashtagTests {

    @Test func extractsTagsInOrderOfFirstAppearance() {
        let tags = SearchViewModel.hashtags(in: [
            "Loving #SwiftUI and #iOS today",
            "More #swiftui tips!",
            "#WWDC was great",
        ])
        #expect(tags == ["SwiftUI", "iOS", "WWDC"])
    }

    @Test func stripsTrailingPunctuation() {
        #expect(SearchViewModel.hashtags(in: ["Check #bluesky, #atproto."]) == ["bluesky", "atproto"])
    }

    @Test func ignoresBareHashAndNumbersOnly() {
        #expect(SearchViewModel.hashtags(in: ["# alone and #123 and #2024"]).isEmpty)
    }

    @Test func emptyInputYieldsNothing() {
        #expect(SearchViewModel.hashtags(in: []).isEmpty)
        #expect(SearchViewModel.hashtags(in: ["no tags here"]).isEmpty)
    }
}
