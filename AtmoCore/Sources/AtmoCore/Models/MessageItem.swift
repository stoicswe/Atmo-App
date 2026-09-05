import Foundation
import ATProtoKit

public struct MessageItem: Identifiable, Hashable, Sendable {
    public let id: String  // == messageID
    public let messageID: String
    public let senderDID: String
    public let text: String
    public let sentAt: Date
    /// A post shared into the chat (`app.bsky.embed.record#view`), when
    /// the message carries one. Rendered as a quote card that opens the
    /// post in the app; unavailable/blocked records render as a notice.
    public let embeddedRecord: AppBskyLexicon.Embed.RecordDefinition.View?

    /// The shared post's AT URI, when the embed resolved to a live post.
    public var embeddedPostURI: String? { Self.postURI(in: embeddedRecord) }

    /// Preview line for conversation lists and notifications: the text,
    /// or a stand-in when the message is only a shared post.
    public var previewText: String { Self.previewText(text: text, hasEmbed: embeddedRecord != nil) }

    public init(messageView: ChatBskyLexicon.Conversation.MessageViewDefinition) {
        self.messageID = messageView.messageID
        self.id = messageView.messageID
        self.senderDID = messageView.sender.authorDID
        self.text = messageView.text
        self.sentAt = messageView.sentAt
        if case .recordView(let view) = messageView.embed {
            self.embeddedRecord = view
        } else {
            self.embeddedRecord = nil
        }
    }

    nonisolated static func postURI(in record: AppBskyLexicon.Embed.RecordDefinition.View?) -> String? {
        guard let record, case .viewRecord(let view) = record.record else { return nil }
        return view.uri
    }

    nonisolated static func previewText(text: String, hasEmbed: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, hasEmbed { return "Shared a post" }
        return text
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: MessageItem, rhs: MessageItem) -> Bool { lhs.id == rhs.id }

    /// Internal test fixture initializer.
    init(testID: String, senderDID: String, text: String = "", sentAt: Date) {
        self.messageID = testID
        self.id = testID
        self.senderDID = senderDID
        self.text = text
        self.sentAt = sentAt
        self.embeddedRecord = nil
    }
}
