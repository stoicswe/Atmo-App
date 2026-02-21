import SwiftUI
import ATProtoKit

/// Renders AT Protocol rich text with tappable @mentions, #hashtags, and URLs.
///
/// Mentions  → `atmo://profile/<handle>` link → fires `onMentionTap`
/// Hashtags  → `atmo://hashtag/<tag>`   link → fires `onHashtagTap`
/// URLs      → standard `.link` attribute    → opens in default browser via `.systemAction`
///
/// When `facets` are provided (from the AT Protocol PostRecord), they are used as the
/// primary source for URL detection — this handles truncated display URLs like
/// "www.nasa.gov/blogs/missio..." by linking to the full canonical URI stored in the
/// facet. When no facets are provided, regex-based detection is used as a fallback.
///
/// All three use `.link` attributes on the `AttributedString` so the tap targets are
/// precisely the marked runs — plain body text falls through to the parent view's gesture.
///
/// Usage:
///   RichTextView(text: post.displayText,
///                facets: post.facets,
///                onMentionTap: { handle in navPath.append(handle) },
///                onHashtagTap: { tag in searchViewModel.activateHashtag(tag) })
struct RichTextView: View {
    let text: String
    /// AT Protocol server-provided facets. Used as the primary source for URL
    /// attribution — avoids relying on regex/NSDataDetector which can't handle
    /// truncated display URLs (e.g. "www.nasa.gov/blogs/missio...").
    var facets: [AppBskyLexicon.RichText.Facet] = []
    /// Called when the user taps a @mention. Receives the handle without the leading "@".
    var onMentionTap: ((String) -> Void)? = nil
    /// Called when the user taps a #hashtag. Receives the tag without the leading "#".
    var onHashtagTap: ((String) -> Void)? = nil

    var body: some View {
        Text(styledText)
            .font(AtmoFonts.postText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                // Intercept custom mention scheme: atmo://profile/<handle-or-did>
                if url.scheme == "atmo", url.host == "profile",
                   let handle = url.pathComponents.dropFirst().first {
                    let decoded = handle.removingPercentEncoding ?? handle
                    onMentionTap?(decoded)
                    return .handled
                }
                // Intercept custom hashtag scheme: atmo://hashtag/<tag>
                if url.scheme == "atmo", url.host == "hashtag",
                   let tag = url.pathComponents.dropFirst().first {
                    let decoded = tag.removingPercentEncoding ?? tag
                    onHashtagTap?(decoded)
                    return .handled
                }
                // Let the system handle real http/https URLs
                return .systemAction
            })
    }

    private var styledText: AttributedString {
        var attributed = AttributedString(text)
        // Order matters: server facets first (most authoritative, covers truncated URLs).
        // Regex-based mention and hashtag detection runs after as a fallback for
        // posts that lack server facets (e.g. synthetic/pending items).
        // Hashtags run last so they don't re-colour a URL fragment.
        applyFacetLinks(to: &attributed)
        applyMentionLinks(to: &attributed)
        applyHashtagLinks(to: &attributed)
        return attributed
    }

    // MARK: - Server Facet Links (primary source)

    /// Applies link, mention, and hashtag attributes using server-provided AT Protocol
    /// facets. This is the most accurate source — handles truncated display URLs,
    /// non-http-prefixed links, and anything regex-based detection can't detect.
    ///
    /// AT Protocol facet byte offsets are in UTF-8 byte positions, so we work with
    /// the UTF-8 view of the string to convert them to Swift `String.Index` values.
    private func applyFacetLinks(to attributed: inout AttributedString) {
        guard !facets.isEmpty else { return }

        let utf8 = text.utf8

        for facet in facets {
            let byteStart = facet.index.byteStart
            let byteEnd   = facet.index.byteEnd

            // Validate byte bounds
            guard byteStart >= 0,
                  byteEnd > byteStart,
                  byteEnd <= utf8.count
            else { continue }

            // Convert UTF-8 byte offsets → String.Index
            // We advance in the UTF-8 view and then convert back to a String index.
            let utf8Start = utf8.index(utf8.startIndex, offsetBy: byteStart)
            let utf8End   = utf8.index(utf8.startIndex, offsetBy: byteEnd)

            // A UTF-8 index is valid as a String.Index because String's UTF-8 view
            // indices are interchangeable with String.Index values in Swift.
            let stringStart = utf8Start.samePosition(in: text) ?? text.startIndex
            let stringEnd   = utf8End.samePosition(in: text)   ?? text.endIndex

            guard stringStart < stringEnd,
                  stringStart >= text.startIndex,
                  stringEnd   <= text.endIndex
            else { continue }

            let stringRange = stringStart..<stringEnd
            guard let attrRange = Range(stringRange, in: attributed) else { continue }

            for feature in facet.features {
                switch feature {
                case .link(let link):
                    // Use the canonical URI from the facet even when the display text is truncated
                    if let url = URL(string: link.uri) {
                        attributed[attrRange].link = url
                        attributed[attrRange].foregroundColor = AtmoColors.skyBlue
                    }

                case .mention(let mention):
                    // Link via DID — the openURL handler fires onMentionTap with the DID.
                    // Note: onMentionTap currently expects a handle, but DID also works for
                    // NavigationLink(value:) — ProfileView resolves either form.
                    let encoded = mention.did.addingPercentEncoding(
                        withAllowedCharacters: .urlPathAllowed
                    ) ?? mention.did
                    attributed[attrRange].link = URL(string: "atmo://profile/\(encoded)")
                    attributed[attrRange].foregroundColor = AtmoColors.skyBlue

                case .tag(let tagFeature):
                    let encoded = tagFeature.tag.addingPercentEncoding(
                        withAllowedCharacters: .urlPathAllowed
                    ) ?? tagFeature.tag
                    attributed[attrRange].link = URL(string: "atmo://hashtag/\(encoded)")
                    attributed[attrRange].foregroundColor = AtmoColors.skyBlue

                default:
                    // .unknown or future feature types — skip
                    break
                }
            }
        }
    }

    // MARK: - Mention links (regex fallback)

    /// Colours @mentions sky-blue and attaches a tappable `atmo://profile/<handle>` link.
    /// Only applied to runs not already covered by server facets.
    private func applyMentionLinks(to attributed: inout AttributedString) {
        guard let regex = try? NSRegularExpression(
            pattern: #"@([\w][\w.-]*[\w]|[\w]+)"#
        ) else { return }

        let nsString = text as NSString
        let matches  = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            let fullNSRange   = match.range          // includes "@"
            let handleNSRange = match.range(at: 1)  // capture group — handle only

            guard let fullStringRange   = Range(fullNSRange,   in: text),
                  let handleStringRange = Range(handleNSRange, in: text),
                  let attrRange         = Range(fullStringRange, in: attributed)
            else { continue }

            // Skip if already attributed by server facets
            if attributed[attrRange].link != nil { continue }

            let handle  = String(text[handleStringRange])
            let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle

            attributed[attrRange].foregroundColor = AtmoColors.skyBlue
            attributed[attrRange].link = URL(string: "atmo://profile/\(encoded)")
        }
    }

    // MARK: - Hashtag links (regex fallback)

    /// Colours #hashtags sky-blue and attaches a tappable `atmo://hashtag/<tag>` link.
    /// Runs after `applyFacetLinks` so server-annotated tags are already covered.
    private func applyHashtagLinks(to attributed: inout AttributedString) {
        // Match # followed by one or more word characters.
        // The negative look-behind (?<!\w) prevents matching mid-word "#" (e.g. in URLs).
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<!\w)#(\w+)"#
        ) else { return }

        let nsString = text as NSString
        let matches  = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            let fullNSRange = match.range         // includes "#"
            let tagNSRange  = match.range(at: 1) // capture group — tag word only

            guard let fullStringRange = Range(fullNSRange, in: text),
                  let tagStringRange  = Range(tagNSRange,  in: text),
                  let attrRange       = Range(fullStringRange, in: attributed)
            else { continue }

            // Skip if this range already has a link (e.g. from server facets or a URL)
            if attributed[attrRange].link != nil { continue }

            let tag     = String(text[tagStringRange])
            let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag

            attributed[attrRange].foregroundColor = AtmoColors.skyBlue
            attributed[attrRange].link = URL(string: "atmo://hashtag/\(encoded)")
        }
    }
}
