import Foundation

// MARK: - Chat Capabilities
/// What Bluesky's chat lexicon lets a message carry. Today
/// (`chat.bsky.convo.defs#messageInput`) an embed may only be a post
/// record or a join link — no images, video, or audio. The DM "+" menu
/// declares its media rows behind `supportsMedia`, so when Bluesky adds
/// media embeds the work is flipping this flag (and wiring the upload),
/// not redesigning the menu.
public enum ChatCapabilities {
    /// Photos, videos, voice memos, drawings, generated images in DMs.
    public static let supportsMedia = false
    /// GIFs travel as a link in the text; every chat renders them.
    public static let supportsGIFLinks = true
    /// A post shared as a record embed.
    public static let supportsPostEmbeds = true
}
