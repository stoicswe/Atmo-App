import Foundation
import ATProtoKit

/// One run of a post's text with the rich-text feature that covers it.
///
/// Front ends without an attributed-string type (the GTK app builds Pango
/// markup) render posts from these runs; SwiftUI can build an
/// `AttributedString` from them the same way. Segments are contiguous and
/// concatenate back to the source text.
public struct RichTextSegment: Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        case plain
        /// A web link. The URL is the facet's canonical URI, which may be
        /// longer than the (possibly truncated) display text.
        case link(URL)
        /// An @mention. `actor` is the DID from a server facet, or the bare
        /// handle when detected from the text alone — profile lookups accept
        /// either.
        case mention(actor: String)
        /// A #hashtag, without the leading `#`.
        case tag(String)
    }

    public let text: String
    public let kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    public var isPlain: Bool {
        if case .plain = kind { return true }
        return false
    }
}

public enum RichText {

    /// A byte range of the source text and the feature covering it.
    struct Span {
        let start: Int
        let end: Int
        let kind: RichTextSegment.Kind
    }

    /// Splits `text` into runs by the server-provided facets (UTF-8 byte
    /// ranges). Facets that overlap, run backwards, or fall outside the
    /// text are skipped; facets with no renderable feature stay plain.
    ///
    /// When there are no facets at all, @mentions and #hashtags are
    /// detected from the text itself so synthetic or pending posts still
    /// get tappable runs.
    public static func segments(
        text: String,
        facets: [AppBskyLexicon.RichText.Facet]
    ) -> [RichTextSegment] {
        guard !text.isEmpty else { return [] }
        let utf8 = Array(text.utf8)
        let total = utf8.count

        var spans: [Span] = []
        for facet in facets {
            let start = facet.index.byteStart
            let end = facet.index.byteEnd
            guard start >= 0, end > start, end <= total else { continue }
            guard let kind = kind(for: facet) else { continue }
            spans.append(Span(start: start, end: end, kind: kind))
        }
        if facets.isEmpty {
            spans = detectedSpans(in: text)
        }

        // Earliest first; drop anything overlapping an accepted span.
        spans.sort { $0.start < $1.start }
        var accepted: [Span] = []
        var cursor = 0
        for span in spans where span.start >= cursor {
            accepted.append(span)
            cursor = span.end
        }

        var segments: [RichTextSegment] = []
        var position = 0
        func run(_ start: Int, _ end: Int) -> String? {
            guard end > start else { return nil }
            return String(bytes: utf8[start..<end], encoding: .utf8)
        }
        for span in accepted {
            if let plain = run(position, span.start) {
                segments.append(RichTextSegment(text: plain, kind: .plain))
            }
            if let featured = run(span.start, span.end) {
                segments.append(RichTextSegment(text: featured, kind: span.kind))
            } else {
                // A boundary inside a multi-byte scalar is malformed: keep
                // the bytes as plain text rather than dropping them.
                let lossy = String(decoding: utf8[span.start..<span.end], as: UTF8.self)
                segments.append(RichTextSegment(text: lossy, kind: .plain))
            }
            position = span.end
        }
        if let tail = run(position, total) {
            segments.append(RichTextSegment(text: tail, kind: .plain))
        }
        return segments
    }

    private static func kind(for facet: AppBskyLexicon.RichText.Facet) -> RichTextSegment.Kind? {
        for feature in facet.features {
            switch feature {
            case .link(let link):
                if let url = URL(string: link.uri) { return .link(url) }
            case .mention(let mention):
                return .mention(actor: mention.did)
            case .tag(let tag):
                return .tag(tag.tag)
            default:
                continue
            }
        }
        return nil
    }

    /// Regex fallback for facet-less text: `@handle.tld` and `#tag`.
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![\w@])@([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+)"#
    )
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"(?<![\w#])#([\p{L}\p{N}_]+)"#
    )

    static func detectedSpans(in text: String) -> [Span] {
        let nsText = text as NSString
        let whole = NSRange(location: 0, length: nsText.length)
        var spans: [Span] = []
        func byteOffset(ofUTF16 location: Int) -> Int {
            nsText.substring(to: location).utf8.count
        }
        for match in mentionPattern.matches(in: text, range: whole) {
            let handle = nsText.substring(with: match.range(at: 1))
            spans.append(Span(
                start: byteOffset(ofUTF16: match.range.location),
                end: byteOffset(ofUTF16: match.range.location + match.range.length),
                kind: .mention(actor: handle)
            ))
        }
        for match in tagPattern.matches(in: text, range: whole) {
            let tag = nsText.substring(with: match.range(at: 1))
            spans.append(Span(
                start: byteOffset(ofUTF16: match.range.location),
                end: byteOffset(ofUTF16: match.range.location + match.range.length),
                kind: .tag(tag)
            ))
        }
        return spans
    }
}

extension PostItem {

    /// `displayText` split into rich-text runs. Facets are relative to the
    /// full record text; `displayText` only ever trims a trailing link, so
    /// every facet still inside it keeps its offsets.
    public var richTextSegments: [RichTextSegment] {
        let shown = displayText
        let visibleBytes = shown.utf8.count
        let usable = facets.filter { $0.index.byteEnd <= visibleBytes }
        return RichText.segments(text: shown, facets: usable)
    }
}
