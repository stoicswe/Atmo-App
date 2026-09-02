import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ATProtoKit

// MARK: - Bluesky CDN
/// The image CDN serves fixed presets by path segment. Measured (Sept
/// 2026): `feed_thumbnail` is 1000 px on the long edge (~43 KB),
/// `feed_fullsize` 3300 px (~174 KB), `avatar` 1000 px (~12 KB), and
/// `avatar_thumbnail` 128 px (~1.4 KB) — WebP regardless of the suffix.
/// The API hands out `feed_*` for posts and the large `avatar` preset for
/// profiles; these helpers pick the cheap variant where the pixels would
/// be thrown away anyway.
public enum BlueskyCDN {

    /// The 128 px avatar preset for small avatar views. Non-CDN or
    /// already-small URLs pass through unchanged.
    public static func avatarThumbnail(_ url: URL) -> URL {
        rewrite(url, from: "/img/avatar/", to: "/img/avatar_thumbnail/")
    }

    /// The 1000 px post-image preset from a full-size URL.
    public static func feedThumbnail(_ url: URL) -> URL {
        rewrite(url, from: "/img/feed_fullsize/", to: "/img/feed_thumbnail/")
    }

    /// The 3300 px post-image preset from a thumbnail URL.
    public static func feedFullsize(_ url: URL) -> URL {
        rewrite(url, from: "/img/feed_thumbnail/", to: "/img/feed_fullsize/")
    }

    /// The repository DID and blob CID a CDN image URL was rendered from:
    /// `/img/<preset>/plain/<did>/<cid>[@ext]`. Those two identify the
    /// original upload on the author's PDS (`com.atproto.sync.getBlob`).
    public static func blobReference(from url: URL) -> (did: String, cid: String)? {
        guard isCDNImage(url) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        // ["img", preset, "plain", did, cid@ext]
        guard parts.count >= 5, parts[0] == "img", parts[2] == "plain" else { return nil }
        let did = parts[3]
        let cid = parts[4].split(separator: "@").first.map(String.init) ?? parts[4]
        guard did.hasPrefix("did:"), !cid.isEmpty else { return nil }
        return (did, cid)
    }

    /// The `getBlob` request for an original upload on `pdsURL`.
    public static func blobURL(pdsURL: URL, did: String, cid: String) -> URL? {
        var components = URLComponents(url: pdsURL.appendingPathComponent("xrpc/com.atproto.sync.getBlob"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "did", value: did), URLQueryItem(name: "cid", value: cid)]
        return components?.url
    }

    public static func isCDNImage(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().hasSuffix("cdn.bsky.app") && url.path.hasPrefix("/img/")
    }

    private static func rewrite(_ url: URL, from: String, to: String) -> URL {
        guard isCDNImage(url), url.path.hasPrefix(from),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.path = to + url.path.dropFirst(from.count)
        return components.url ?? url
    }
}


// MARK: - Original Image Source
/// Fetches the bytes the author actually uploaded — the CDN presets are
/// re-encoded copies — by resolving the author's PDS from the DID in the
/// image URL and asking it for the blob. Falls back to nil for non-CDN
/// images or when the PDS can't be reached.
public enum OriginalImageSource {
    public static func fetchOriginal(for cdnURL: URL, session: URLSession = .shared) async -> Data? {
        guard let ref = BlueskyCDN.blobReference(from: cdnURL),
              let endpoint = try? await ATBuiltInIdentityResolver(urlSession: session).resolvePDSEndpoint(from: ref.did),
              let pds = URL(string: endpoint),
              let url = BlueskyCDN.blobURL(pdsURL: pds, did: ref.did, cid: ref.cid)
        else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }
}
