import Foundation
import Testing
import ATProtoKit
@testable import AtmoCore

/// Covers the platform-neutral embed digest (`PostItem.embedContent`)
/// simpler front ends render instead of ATProtoKit's nested unions.
struct EmbedContentTests {

    private let thumb = URL(string: "https://cdn.example/thumb.jpg")!
    private let full = URL(string: "https://cdn.example/full.jpg")!

    private func post(embed: AppBskyLexicon.Feed.PostViewDefinition.EmbedUnion?) -> PostItem {
        PostItem(testURI: "at://did:t/app.bsky.feed.post/embed", embed: embed)
    }

    private var imagesView: AppBskyLexicon.Embed.ImagesDefinition.View {
        .init(images: [
            .init(thumbnailImageURL: thumb, fullSizeImageURL: full, altText: "a cat", aspectRatio: nil)
        ])
    }

    private var externalView: AppBskyLexicon.Embed.ExternalDefinition.View {
        .init(external: .init(
            uri: "https://example.com/story",
            title: "A story",
            description: "Worth reading",
            thumbnailImageURL: nil
        ))
    }

    @Test func noEmbedYieldsNil() {
        #expect(post(embed: nil).embedContent == nil)
    }

    @Test func imagesSurfaceThumbFullAndAlt() {
        let content = post(embed: .embedImagesView(imagesView)).embedContent
        #expect(content?.images.count == 1)
        #expect(content?.images.first?.thumbnailURL == thumb)
        #expect(content?.images.first?.fullSizeURL == full)
        #expect(content?.images.first?.altText == "a cat")
        #expect(content?.externalLink == nil)
        #expect(content?.quote == nil)
    }

    @Test func externalLinkSurfacesTitleAndHost() {
        let content = post(embed: .embedExternalView(externalView)).embedContent
        #expect(content?.externalLink?.title == "A story")
        #expect(content?.externalLink?.host == "example.com")
        #expect(content?.externalLink?.uri == "https://example.com/story")
    }

    @Test func videoSurfacesStreamThumbAndSize() {
        let video = AppBskyLexicon.Embed.VideoDefinition.View(
            cid: "cid", playlistURI: "https://cdn.example/v.m3u8",
            thumbnailImageURL: "https://cdn.example/v.jpg", altText: "a demo",
            aspectRatio: .init(width: 1920, height: 1080)
        )
        let content = post(embed: .embedVideoView(video)).embedContent
        #expect(content?.hasVideo == true)
        #expect(content?.video?.playlistURL == URL(string: "https://cdn.example/v.m3u8"))
        #expect(content?.video?.thumbnailURL == URL(string: "https://cdn.example/v.jpg"))
        #expect(content?.video?.altText == "a demo")
        #expect(content?.video?.width == 1920)
        #expect(content?.video?.height == 1080)
        #expect(content?.isEmpty == false)
    }

    @Test func externalLinkCarriesThumbnail() {
        let external = AppBskyLexicon.Embed.ExternalDefinition.View(external: .init(
            uri: "https://example.com/story",
            title: "A story",
            description: "Worth reading",
            thumbnailImageURL: thumb
        ))
        let content = post(embed: .embedExternalView(external)).embedContent
        #expect(content?.externalLink?.thumbnailURL == thumb)
    }

    /// ViewNotFound has no memberwise initializer (the `$type` constant
    /// suppresses synthesis), so fixtures decode from lexicon JSON.
    private var notFoundRecord: AppBskyLexicon.Embed.RecordDefinition.ViewNotFound {
        let json = """
        {"$type": "app.bsky.embed.record#viewNotFound",
         "uri": "at://did:g/app.bsky.feed.post/gone",
         "notFound": true}
        """
        return try! JSONDecoder().decode(
            AppBskyLexicon.Embed.RecordDefinition.ViewNotFound.self,
            from: Data(json.utf8)
        )
    }

    @Test func recordWithMediaKeepsMediaAndDropsUnresolvableQuote() {
        // A quote of a deleted post alongside images: the images must
        // survive, the quote digest must be nil (not a crash, not junk).
        let record = AppBskyLexicon.Embed.RecordDefinition.View(record: .viewNotFound(notFoundRecord))
        let combined = AppBskyLexicon.Embed.RecordWithMediaDefinition.View(
            record: record, media: .embedImagesView(imagesView)
        )
        let content = post(embed: .embedRecordWithMediaView(combined)).embedContent
        #expect(content?.images.count == 1)
        #expect(content?.quote == nil)
    }

    @Test func unresolvableQuoteAloneYieldsNil() {
        let record = AppBskyLexicon.Embed.RecordDefinition.View(record: .viewNotFound(notFoundRecord))
        #expect(post(embed: .embedRecordView(record)).embedContent == nil)
    }
}
