import Foundation
import Testing
@testable import AtmoCore

/// Covers the GIF picker plumbing (proxy payload decoding, embed URL
/// convention, slot exclusivity) and the waveform bucket math behind the
/// voice-memo renderer.
struct GIFAndWaveformTests {

    // MARK: - GIF payload decoding

    private let fixture = """
    {
      "results": [
        {
          "id": "g1",
          "title": "Happy Dance",
          "content_description": "A dancing cat",
          "media_formats": {
            "gif": { "url": "https://media.tenor.com/abc/dance.gif", "dims": [498, 372] },
            "tinygif": { "url": "https://media.tenor.com/abc/tiny.gif", "dims": [220, 164] }
          }
        },
        {
          "id": "g2",
          "title": "",
          "content_description": "Thumbs up",
          "media_formats": {
            "gif": { "url": "https://media.tenor.com/def/thumbs.gif", "dims": [400, 400] }
          }
        },
        {
          "id": "no-gif-format",
          "title": "Broken",
          "media_formats": {
            "mp4": { "url": "https://media.tenor.com/ghi/clip.mp4", "dims": [1, 1] }
          }
        }
      ]
    }
    """.data(using: .utf8)!

    @Test func decodesProxyPayload() throws {
        let items = try GIFService.decode(fixture)
        #expect(items.count == 2)
        #expect(items[0].id == "g1")
        #expect(items[0].title == "Happy Dance")
        #expect(items[0].previewURL.absoluteString.hasSuffix("tiny.gif"))
        #expect(items[0].width == 498)
        // Empty title falls back to the content description.
        #expect(items[1].title == "Thumbs up")
        // A result without a gif rendition is dropped.
    }

    @Test func garbagePayloadThrowsUnavailable() {
        #expect(throws: GIFService.GIFServiceError.self) {
            try GIFService.decode(Data("Tenor API is discontinued".utf8))
        }
    }

    @Test func embedURLCarriesDimensions() {
        let gif = GIFItem(
            id: "g",
            title: "t",
            gifURL: URL(string: "https://media.tenor.com/x/y.gif")!,
            previewURL: URL(string: "https://media.tenor.com/x/tiny.gif")!,
            width: 498,
            height: 372
        )
        let url = gif.embedURL.absoluteString
        #expect(url.contains("ww=498"))
        #expect(url.contains("hh=372"))
    }

    // MARK: - Slot exclusivity

    @MainActor
    @Test func gifDisplacesOtherMediaAndViceVersa() {
        let slot = PostSlot()
        slot.addImage(data: Data([1]), fileName: "a.jpg")
        let gif = GIFItem(
            id: "g", title: "t",
            gifURL: URL(string: "https://g/x.gif")!,
            previewURL: URL(string: "https://g/t.gif")!,
            width: 1, height: 1
        )
        slot.attachGIF(gif)
        #expect(slot.attachedImages.isEmpty)
        #expect(slot.attachedGIF != nil)

        // Images can't join a GIF; a video displaces it.
        slot.addImage(data: Data([2]), fileName: "b.jpg")
        #expect(slot.attachedImages.isEmpty)
        slot.attachVideo(data: Data([3]), fileName: "v.mp4")
        #expect(slot.attachedGIF == nil)
        #expect(slot.attachedVideo != nil)
    }

    @MainActor
    @Test func mediaOnlyPostsAreSubmittable() {
        let slot = PostSlot()
        #expect(!slot.canSubmit)
        slot.attachGIF(GIFItem(
            id: "g", title: "t",
            gifURL: URL(string: "https://g/x.gif")!,
            previewURL: URL(string: "https://g/t.gif")!,
            width: 1, height: 1
        ))
        #expect(slot.canSubmit)
    }

    // MARK: - Waveform buckets

    @Test func loudestBucketNormalizesToOne() {
        let accumulator = WaveformAccumulator(bucketCount: 4, estimatedFrameCount: 8)
        accumulator.add([0.1, 0.1, 0.5, 0.5, 1.0, 1.0, 0.25, 0.25])
        let buckets = accumulator.normalizedBuckets()
        #expect(buckets.count == 4)
        #expect(buckets[2] == 1.0)
        #expect(abs(buckets[1] - 0.5) < 0.001)
    }

    @Test func silenceStillDrawsAFloor() {
        let accumulator = WaveformAccumulator(bucketCount: 3, estimatedFrameCount: 3)
        accumulator.add([0, 0, 0])
        #expect(accumulator.normalizedBuckets(floor: 0.06).allSatisfy { $0 == 0.06 })
    }

    @Test func overflowFramesFoldIntoLastBucket() {
        // More frames than estimated must not crash — extras land in the
        // final bucket.
        let accumulator = WaveformAccumulator(bucketCount: 2, estimatedFrameCount: 4)
        accumulator.add([0.1, 0.1, 0.2, 0.2, 0.9, 0.9])
        #expect(accumulator.normalizedBuckets()[1] == 1.0)
    }
}
