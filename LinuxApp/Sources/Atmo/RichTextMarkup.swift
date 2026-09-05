import Adwaita
import CAdw
import Foundation
import AtmoCore

/// Pango markup for a post's rich-text runs (core `RichText.segments`):
/// links, @mentions, and #hashtags become `<a>` runs. In-app targets use
/// the `atmo:` scheme so the label's `activate-link` hook can route them
/// to a profile page or a hashtag search instead of the browser.
enum RichTextMarkup {

    static func markup(for segments: [RichTextSegment]) -> String {
        segments.map { segment -> String in
            let text = escape(segment.text)
            switch segment.kind {
            case .plain:
                return text
            case .link(let url):
                return "<a href=\"\(escape(url.absoluteString))\">\(text)</a>"
            case .mention(let actor):
                return "<a href=\"atmo://profile/\(percentEncode(actor))\">\(text)</a>"
            case .tag(let tag):
                return "<a href=\"atmo://hashtag/\(percentEncode(tag))\">\(text)</a>"
            }
        }.joined()
    }

    /// What an activated link means.
    enum Target {
        case profile(actor: String)
        case hashtag(String)
        case web(URL)
    }

    static func target(for uri: String) -> Target? {
        if uri.hasPrefix("atmo://profile/") {
            let raw = String(uri.dropFirst("atmo://profile/".count))
            return .profile(actor: raw.removingPercentEncoding ?? raw)
        }
        if uri.hasPrefix("atmo://hashtag/") {
            let raw = String(uri.dropFirst("atmo://hashtag/".count))
            return .hashtag(raw.removingPercentEncoding ?? raw)
        }
        if let url = URL(string: uri) { return .web(url) }
        return nil
    }

    static func escape(_ text: String) -> String {
        guard let escaped = g_markup_escape_text(text, -1) else { return text }
        defer { g_free(escaped) }
        return String(cString: escaped)
    }

    private static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }
}
