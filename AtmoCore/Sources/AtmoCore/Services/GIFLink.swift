import Foundation

// MARK: - GIF Link
/// A link that should render as an inline, looping GIF instead of a link
/// card — the treatment the official client gives Tenor/KLIPY/Giphy
/// embeds and, here, any URL whose path is a `.gif` file.
///
/// Detection is two-stage by design:
///   1. `parse` is the cheap URL check that decides whether to *attempt*
///      inline playback (the path names a `.gif`, or it's a Giphy page
///      link whose media URL is derivable).
///   2. `isGIFData` verifies the downloaded bytes really are a GIF before
///      anything animates, so a `.gif` URL that serves an HTML page or a
///      WebP falls back to the ordinary link card.
public struct GIFLink: Sendable, Equatable {
    /// The URL to download the GIF bytes from.
    public let mediaURL: URL
    /// Pixel dimensions when the link carries them (`ww`/`hh` query items,
    /// the convention GIF embeds use so feeds can reserve the box early).
    public let width: Int?
    public let height: Int?

    public init(mediaURL: URL, width: Int? = nil, height: Int? = nil) {
        self.mediaURL = mediaURL
        self.width = width
        self.height = height
    }

    /// Width / height when both dimensions are known and sane.
    public var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    // MARK: Parsing

    public static func parse(_ string: String) -> GIFLink? {
        guard let url = URL(string: string) else { return nil }
        return parse(url)
    }

    public static func parse(_ url: URL) -> GIFLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let host = (components.host ?? "").lowercased()
        let items = components.queryItems ?? []
        let width = items.first { $0.name == "ww" }?.value.flatMap(Int.init)
        let height = items.first { $0.name == "hh" }?.value.flatMap(Int.init)

        // Any direct .gif file, whatever the host (media.tenor.com,
        // static.klipy.com, i.giphy.com, a personal server…).
        if components.path.lowercased().hasSuffix(".gif") {
            return GIFLink(mediaURL: url, width: width, height: height)
        }

        // Giphy page links (giphy.com/gifs/<slug>-<id>) — the media file
        // is derivable from the trailing id.
        if host == "giphy.com" || host.hasSuffix(".giphy.com") {
            let parts = components.path.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "gifs",
               let id = parts[1].split(separator: "-").last, !id.isEmpty,
               let media = URL(string: "https://i.giphy.com/media/\(id)/giphy.gif") {
                return GIFLink(mediaURL: media, width: width, height: height)
            }
        }

        return nil
    }

    // MARK: Data check

    /// True when `data` begins with a GIF signature ("GIF87a"/"GIF89a").
    /// Only the header is inspected, so it's safe on partial downloads.
    public static func isGIFData(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        let header = [UInt8](data.prefix(6))
        let prefix: [UInt8] = [0x47, 0x49, 0x46, 0x38] // "GIF8"
        guard Array(header[0..<4]) == prefix else { return false }
        // "7a" or "9a"
        return (header[4] == 0x37 || header[4] == 0x39) && header[5] == 0x61
    }
}
