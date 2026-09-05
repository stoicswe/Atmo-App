import Foundation
import Testing
import ATProtoKit
@testable import AtmoCore

/// Covers `RichText.segments` — the platform-neutral run splitter the GTK
/// app renders posts from (Pango markup) and SwiftUI can adopt.
struct RichTextSegmentTests {

    private func facet(_ start: Int, _ end: Int, _ feature: AppBskyLexicon.RichText.Facet.FeaturesUnion)
        -> AppBskyLexicon.RichText.Facet {
        .init(index: .init(byteStart: start, byteEnd: end), features: [feature])
    }

    @Test func plainTextIsOneRun() {
        let runs = RichText.segments(text: "just words", facets: [])
        #expect(runs == [RichTextSegment(text: "just words", kind: .plain)])
    }

    @Test func emptyTextHasNoRuns() {
        #expect(RichText.segments(text: "", facets: []).isEmpty)
    }

    @Test func facetsSplitByByteOffsets() {
        // "héllo @bob #tag" — é is two bytes, so mention starts at 7.
        let text = "héllo @bob #tag"
        let runs = RichText.segments(text: text, facets: [
            facet(7, 11, .mention(.init(did: "did:plc:bob"))),
            facet(12, 16, .tag(.init(tag: "tag"))),
        ])
        #expect(runs == [
            RichTextSegment(text: "héllo ", kind: .plain),
            RichTextSegment(text: "@bob", kind: .mention(actor: "did:plc:bob")),
            RichTextSegment(text: " ", kind: .plain),
            RichTextSegment(text: "#tag", kind: .tag("tag")),
        ])
        #expect(runs.map(\.text).joined() == text)
    }

    @Test func linkUsesCanonicalURIOverTruncatedDisplay() {
        let text = "see www.nasa.gov/blogs/missio..."
        let runs = RichText.segments(text: text, facets: [
            facet(4, text.utf8.count, .link(.init(uri: "https://www.nasa.gov/blogs/missions/2024"))),
        ])
        #expect(runs.count == 2)
        #expect(runs[1].kind == .link(URL(string: "https://www.nasa.gov/blogs/missions/2024")!))
        #expect(runs[1].text == "www.nasa.gov/blogs/missio...")
    }

    @Test func malformedFacetsAreSkipped() {
        let text = "abc"
        let runs = RichText.segments(text: text, facets: [
            facet(-1, 2, .tag(.init(tag: "x"))),   // negative start
            facet(2, 1, .tag(.init(tag: "y"))),    // backwards
            facet(0, 99, .tag(.init(tag: "z"))),   // past the end
        ])
        #expect(runs == [RichTextSegment(text: "abc", kind: .plain)])
    }

    @Test func overlappingFacetsKeepTheEarliest() {
        let text = "0123456789"
        let runs = RichText.segments(text: text, facets: [
            facet(2, 6, .tag(.init(tag: "a"))),
            facet(4, 8, .tag(.init(tag: "b"))),
        ])
        #expect(runs.map(\.kind) == [.plain, .tag("a"), .plain])
        #expect(runs.map(\.text).joined() == text)
    }

    @Test func fallbackDetectsMentionsAndTagsWithoutFacets() {
        let runs = RichText.segments(text: "hi @alice.bsky.social, #Swift rocks", facets: [])
        #expect(runs.contains(RichTextSegment(text: "@alice.bsky.social", kind: .mention(actor: "alice.bsky.social"))))
        #expect(runs.contains(RichTextSegment(text: "#Swift", kind: .tag("Swift"))))
        #expect(runs.map(\.text).joined() == "hi @alice.bsky.social, #Swift rocks")
    }

    @Test func fallbackIgnoresEmailsAndBareAtSigns() {
        let runs = RichText.segments(text: "mail me@example.com or @ nobody", facets: [])
        #expect(runs.allSatisfy { $0.isPlain })
    }

    @Test func postSegmentsDropFacetsPastTheTrimmedDisplayText() {
        // A post with a trailing link card URL: displayText strips it, and
        // the facet covering it must not resurface.
        let uri = "https://example.com/story"
        let text = "Read this \(uri)"
        let external = AppBskyLexicon.Embed.ExternalDefinition.View(external: .init(
            uri: uri, title: "t", description: "d", thumbnailImageURL: nil
        ))
        let post = PostItem(
            testURI: "at://did:t/app.bsky.feed.post/1",
            text: text,
            embed: .embedExternalView(external),
            facets: [facet(10, text.utf8.count, .link(.init(uri: uri)))]
        )
        #expect(post.displayText == "Read this")
        #expect(post.richTextSegments == [RichTextSegment(text: "Read this", kind: .plain)])
    }
}
