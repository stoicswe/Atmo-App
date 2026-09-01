import Foundation
import Testing
@testable import AtmoCore

/// Covers the save-to-Photos blob chain: playlist parsing, DID document
/// location, PDS endpoint extraction, and getBlob URL assembly.
struct VideoBlobLocatorTests {

    // MARK: - Playlist parsing

    @Test func parsesEncodedWatchPlaylistURL() throws {
        let url = URL(string:
            "https://video.bsky.app/watch/did%3Aplc%3Aabc123/bafkreihash/playlist.m3u8")!
        let ref = try #require(VideoBlobLocator.parse(playlistURL: url))
        #expect(ref.did == "did:plc:abc123")
        #expect(ref.cid == "bafkreihash")
    }

    @Test func rejectsNonWatchURLs() {
        let thumbnail = URL(string:
            "https://video.bsky.app/thumbnails/did%3Aplc%3Aabc/bafk/thumb.jpg")!
        #expect(VideoBlobLocator.parse(playlistURL: thumbnail) == nil)

        let notADID = URL(string:
            "https://video.bsky.app/watch/someone/bafk/playlist.m3u8")!
        #expect(VideoBlobLocator.parse(playlistURL: notADID) == nil)

        let truncated = URL(string: "https://video.bsky.app/watch/did%3Aplc%3Aabc")!
        #expect(VideoBlobLocator.parse(playlistURL: truncated) == nil)
    }

    // MARK: - DID document URLs

    @Test func plcDIDsResolveThroughDirectory() {
        let url = VideoBlobLocator.didDocumentURL(forDID: "did:plc:abc123")
        #expect(url?.absoluteString == "https://plc.directory/did:plc:abc123")
    }

    @Test func webDIDsResolveToWellKnown() {
        let url = VideoBlobLocator.didDocumentURL(forDID: "did:web:example.com")
        #expect(url?.absoluteString == "https://example.com/.well-known/did.json")
    }

    @Test func unknownDIDMethodsReturnNil() {
        #expect(VideoBlobLocator.didDocumentURL(forDID: "did:key:zXyz") == nil)
        #expect(VideoBlobLocator.didDocumentURL(forDID: "not-a-did") == nil)
    }

    // MARK: - PDS endpoint extraction

    @Test func findsPDSByServiceID() throws {
        let doc = """
        {"id":"did:plc:abc","service":[
          {"id":"#atproto_labeler","type":"AtprotoLabeler","serviceEndpoint":"https://labeler.example"},
          {"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}
        ]}
        """.data(using: .utf8)!
        let url = try #require(VideoBlobLocator.pdsEndpoint(inDIDDocument: doc))
        #expect(url.absoluteString == "https://pds.example.com")
    }

    @Test func findsPDSByTypeWhenIDDiffers() throws {
        let doc = """
        {"service":[{"id":"did:plc:abc#atproto_pds","type":"AtprotoPersonalDataServer",
          "serviceEndpoint":"https://bsky.social"}]}
        """.data(using: .utf8)!
        let url = try #require(VideoBlobLocator.pdsEndpoint(inDIDDocument: doc))
        #expect(url.absoluteString == "https://bsky.social")
    }

    @Test func missingOrMalformedServiceReturnsNil() {
        let noService = #"{"id":"did:plc:abc"}"#.data(using: .utf8)!
        #expect(VideoBlobLocator.pdsEndpoint(inDIDDocument: noService) == nil)

        let badEndpoint = """
        {"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer",
          "serviceEndpoint":"not a url"}]}
        """.data(using: .utf8)!
        #expect(VideoBlobLocator.pdsEndpoint(inDIDDocument: badEndpoint) == nil)

        #expect(VideoBlobLocator.pdsEndpoint(inDIDDocument: Data([0x00])) == nil)
    }

    // MARK: - Blob URL assembly

    @Test func buildsGetBlobURLWithEncodedQuery() throws {
        let url = try #require(VideoBlobLocator.blobURL(
            pds: URL(string: "https://pds.example.com")!,
            reference: .init(did: "did:plc:abc123", cid: "bafkreihash")
        ))
        #expect(url.absoluteString ==
            "https://pds.example.com/xrpc/com.atproto.sync.getBlob?did=did:plc:abc123&cid=bafkreihash")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        #expect(items.first { $0.name == "did" }?.value == "did:plc:abc123")
        #expect(items.first { $0.name == "cid" }?.value == "bafkreihash")
    }
}
