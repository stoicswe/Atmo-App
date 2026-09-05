import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Video Blob Locator
/// Locates the original uploaded video blob (a plain MP4) behind a Bluesky
/// HLS stream, for save-to-Photos. HLS playlists can't be saved as a video
/// file, but every stream on `video.bsky.app` is transcoded from a blob
/// the author's PDS still serves verbatim via `com.atproto.sync.getBlob`.
///
/// The chain, all derivable without a session:
///   1. `parse(playlistURL:)` — the playlist path embeds the author's DID
///      and the blob CID: `…/watch/<did>/<cid>/playlist.m3u8`.
///   2. `didDocumentURL(forDID:)` — where the DID document lives
///      (plc.directory for `did:plc`, `/.well-known/did.json` for `did:web`).
///   3. `pdsEndpoint(inDIDDocument:)` — the PDS service endpoint from the
///      fetched document.
///   4. `blobURL(pds:reference:)` — the final getBlob URL.
///
/// All four steps are pure (the caller does the fetching), so they test on
/// macOS and Linux alike.
public enum VideoBlobLocator {

    /// The author DID and blob CID a playlist URL names.
    public struct Reference: Equatable, Sendable {
        public let did: String
        public let cid: String

        public init(did: String, cid: String) {
            self.did = did
            self.cid = cid
        }
    }

    /// Extracts the DID + CID from a Bluesky video playlist URL
    /// (`https://video.bsky.app/watch/<did>/<cid>/playlist.m3u8`).
    /// Returns nil for URLs that don't follow the watch layout.
    public static func parse(playlistURL: URL) -> Reference? {
        // pathComponents percent-decodes, so an encoded `did%3Aplc%3A…`
        // arrives here as `did:plc:…` already.
        let components = playlistURL.pathComponents
        guard let watchIndex = components.firstIndex(of: "watch"),
              components.count > watchIndex + 2
        else { return nil }
        let did = components[watchIndex + 1]
        let cid = components[watchIndex + 2]
        guard did.hasPrefix("did:"), !cid.isEmpty, cid != "playlist.m3u8" else { return nil }
        return Reference(did: did, cid: cid)
    }

    /// Where the DID document for this DID can be fetched.
    public static func didDocumentURL(forDID did: String) -> URL? {
        if did.hasPrefix("did:plc:") {
            return URL(string: "https://plc.directory/\(did)")
        }
        if did.hasPrefix("did:web:") {
            // did:web encodes the host after the method; ports arrive
            // percent-encoded (`%3A`).
            let host = String(did.dropFirst("did:web:".count))
                .removingPercentEncoding ?? String(did.dropFirst("did:web:".count))
            guard !host.isEmpty, !host.contains("/") else { return nil }
            return URL(string: "https://\(host)/.well-known/did.json")
        }
        return nil
    }

    /// The PDS service endpoint declared in a DID document: the service
    /// entry with id `#atproto_pds` (or type `AtprotoPersonalDataServer`).
    public static func pdsEndpoint(inDIDDocument data: Data) -> URL? {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let services = document["service"] as? [[String: Any]]
        else { return nil }

        let pds = services.first { entry in
            let id = entry["id"] as? String
            let type = entry["type"] as? String
            return id?.hasSuffix("#atproto_pds") == true
                || type == "AtprotoPersonalDataServer"
        }
        guard let endpoint = pds?["serviceEndpoint"] as? String,
              let url = URL(string: endpoint),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url
    }

    /// Runs the whole chain: the original upload's getBlob URL for a
    /// playlist, or nil when any hop fails. Shared by save-to-Photos and
    /// the player's Original quality switch.
    public static func resolveBlobURL(playlistURL: URL, session: URLSession = .shared) async -> URL? {
        guard let reference = parse(playlistURL: playlistURL),
              let documentURL = didDocumentURL(forDID: reference.did),
              let (document, response) = try? await session.data(from: documentURL),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let pds = pdsEndpoint(inDIDDocument: document)
        else { return nil }
        return blobURL(pds: pds, reference: reference)
    }

    /// The `com.atproto.sync.getBlob` URL on the author's PDS for the
    /// original video upload.
    public static func blobURL(pds: URL, reference: Reference) -> URL? {
        var components = URLComponents(
            url: pds.appendingPathComponent("xrpc/com.atproto.sync.getBlob"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "did", value: reference.did),
            URLQueryItem(name: "cid", value: reference.cid),
        ]
        return components?.url
    }
}
