import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - GIF Item
/// One pickable GIF from the search service.
public struct GIFItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    /// Full-size animated GIF (what gets embedded in the post).
    public let gifURL: URL
    /// Small preview used in the picker grid and as the embed thumbnail.
    public let previewURL: URL
    public let width: Int
    public let height: Int

    public init(id: String, title: String, gifURL: URL, previewURL: URL, width: Int, height: Int) {
        self.id = id
        self.title = title
        self.gifURL = gifURL
        self.previewURL = previewURL
        self.width = width
        self.height = height
    }

    /// The URL Bluesky clients embed: the GIF's media URL carrying its
    /// dimensions as `ww`/`hh` query items, which feed renderers use to
    /// reserve the right box (the convention the official app follows).
    public var embedURL: URL {
        guard var components = URLComponents(url: gifURL, resolvingAgainstBaseURL: false) else {
            return gifURL
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "ww" }) {
            items.append(URLQueryItem(name: "ww", value: String(width)))
        }
        if !items.contains(where: { $0.name == "hh" }) {
            items.append(URLQueryItem(name: "hh", value: String(height)))
        }
        components.queryItems = items
        return components.url ?? gifURL
    }
}

// MARK: - GIF Service
/// GIF search through Bluesky's own proxy (gifs.bsky.app) — the same
/// selection the official app offers, no API key needed client-side.
///
/// NOTE (Aug 2026): Google discontinued the Tenor API on 2026-06-30 and
/// Bluesky is migrating the proxy to a successor provider. Until that
/// lands the proxy returns an error, which surfaces here as
/// `GIFServiceError.unavailable` — the picker shows a friendly notice and
/// the feature lights up automatically once the proxy is back.
public enum GIFService {

    public enum GIFServiceError: Error {
        case unavailable
        case badResponse
    }

    static let baseURL = URL(string: "https://gifs.bsky.app/tenor/v2")!

    public static func featured(limit: Int = 30) async throws -> [GIFItem] {
        try await fetch(path: "featured", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    public static func search(_ query: String, limit: Int = 30) async throws -> [GIFItem] {
        try await fetch(path: "search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    private static func fetch(path: String, query: [URLQueryItem]) async throws -> [GIFItem] {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GIFServiceError.unavailable
        }
        return try decode(data)
    }

    /// Decodes the proxy's Tenor-v2-shaped payload. Internal so the unit
    /// tests can exercise it with fixture JSON.
    static func decode(_ data: Data) throws -> [GIFItem] {
        struct Response: Decodable {
            struct Result: Decodable {
                struct MediaFormat: Decodable {
                    let url: URL
                    let dims: [Int]?
                }
                let id: String
                let title: String?
                let content_description: String?
                let media_formats: [String: MediaFormat]
            }
            let results: [Result]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw GIFServiceError.unavailable
        }
        return decoded.results.compactMap { result in
            guard let gif = result.media_formats["gif"] else { return nil }
            let preview = result.media_formats["tinygif"] ?? gif
            let dims = gif.dims ?? []
            return GIFItem(
                id: result.id,
                title: result.title?.isEmpty == false
                    ? result.title!
                    : (result.content_description ?? "GIF"),
                gifURL: gif.url,
                previewURL: preview.url,
                width: dims.count == 2 ? dims[0] : 0,
                height: dims.count == 2 ? dims[1] : 0
            )
        }
    }
}
