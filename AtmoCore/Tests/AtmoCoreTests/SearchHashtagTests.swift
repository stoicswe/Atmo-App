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

    // MARK: - Topic summary lifecycle

    /// activateTopic sets `query` programmatically, and the search bar's
    /// .onChange echoes that back into onQueryChanged one view-update
    /// later. The summary topic must survive that echo (it used to be
    /// wiped every time, so the summary card never appeared) while a
    /// genuinely different query still dismisses it.
    @Test @MainActor func summaryTopicSurvivesTheSearchBarEcho() {
        let vm = SearchViewModel(service: ATProtoService())

        vm.activateTopic("Quantum Computing")
        #expect(vm.summaryTopic == "Quantum Computing")

        // The .onChange(of: query) echo caused by the programmatic set.
        vm.onQueryChanged("Quantum Computing")
        #expect(vm.summaryTopic == "Quantum Computing")

        // The user actually typing something else dismisses the summary.
        vm.onQueryChanged("Quantum Computers")
        #expect(vm.summaryTopic == nil)
    }
}
