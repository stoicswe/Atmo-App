import Foundation
import Testing
@testable import AtmoCore

/// Covers the inline-GIF detection behind link embeds: which URLs are
/// attempted as looping GIFs, the dimensions they carry, and the byte
/// signature check that gates animation.
struct GIFLinkTests {

    // MARK: URL detection

    @Test func tenorGIFWithDimensions() {
        let link = GIFLink.parse("https://media.tenor.com/abc123/dance.gif?hh=372&ww=498")
        #expect(link != nil)
        #expect(link?.mediaURL.absoluteString == "https://media.tenor.com/abc123/dance.gif?hh=372&ww=498")
        #expect(link?.width == 498)
        #expect(link?.height == 372)
        #expect(link?.aspectRatio == 498.0 / 372.0)
    }

    @Test func anyHostDotGIFCounts() {
        #expect(GIFLink.parse("https://static.klipy.com/ii/abc/def.gif") != nil)
        #expect(GIFLink.parse("https://example.org/pictures/cat.GIF") != nil)
        #expect(GIFLink.parse("http://example.org/a.gif") != nil)
    }

    @Test func picksGIFEmbedURLFromPicker() {
        // The composer publishes GIFItem.embedURL — feeds must recognise it.
        let item = GIFItem(
            id: "g1", title: "Wave",
            gifURL: URL(string: "https://media.tenor.com/x/wave.gif")!,
            previewURL: URL(string: "https://media.tenor.com/x/tiny.gif")!,
            width: 300, height: 200
        )
        let link = GIFLink.parse(item.embedURL)
        #expect(link?.width == 300)
        #expect(link?.height == 200)
    }

    @Test func giphyPageLinkResolvesToMedia() {
        let link = GIFLink.parse("https://giphy.com/gifs/happy-dance-cat-l0MYt5jPR6QX5pnqM")
        #expect(link?.mediaURL.absoluteString == "https://i.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif")
        #expect(link?.aspectRatio == nil)
    }

    @Test func nonGIFLinksAreLeftAlone() {
        #expect(GIFLink.parse("https://example.com/article") == nil)
        #expect(GIFLink.parse("https://example.com/video.mp4") == nil)
        #expect(GIFLink.parse("https://example.com/photo.png?name=x.gif") == nil)
        #expect(GIFLink.parse("https://example.com/gifs/not-a-page") == nil)
        #expect(GIFLink.parse("https://example.com/notagif") == nil)
        #expect(GIFLink.parse("ftp://example.com/a.gif") == nil)
        #expect(GIFLink.parse("not a url") == nil)
    }

    @Test func missingOrBrokenDimensions() {
        #expect(GIFLink.parse("https://media.tenor.com/abc/dance.gif")?.aspectRatio == nil)
        #expect(GIFLink.parse("https://media.tenor.com/abc/dance.gif?ww=0&hh=10")?.aspectRatio == nil)
        #expect(GIFLink.parse("https://media.tenor.com/abc/dance.gif?ww=abc&hh=10")?.width == nil)
    }

    // MARK: Byte signature

    @Test func gifSignatures() {
        #expect(GIFLink.isGIFData(Data("GIF89a....".utf8)))
        #expect(GIFLink.isGIFData(Data("GIF87a".utf8)))
        #expect(!GIFLink.isGIFData(Data("GIF8".utf8)))          // too short
        #expect(!GIFLink.isGIFData(Data("GIF88a".utf8)))
        #expect(!GIFLink.isGIFData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]))) // PNG
        #expect(!GIFLink.isGIFData(Data("<!doctype html>".utf8)))
        #expect(!GIFLink.isGIFData(Data()))
    }
}
