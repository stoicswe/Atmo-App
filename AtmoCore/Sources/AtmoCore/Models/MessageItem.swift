import Foundation
import ATProtoKit

public struct MessageItem: Identifiable, Hashable, Sendable {
    public let id: String  // == messageID
    public let messageID: String
    public let senderDID: String
    public let text: String
    public let sentAt: Date

    public init(messageView: ChatBskyLexicon.Conversation.MessageViewDefinition) {
        self.messageID = messageView.messageID
        self.id = messageView.messageID
        self.senderDID = messageView.sender.authorDID
        self.text = messageView.text
        self.sentAt = messageView.sentAt
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: MessageItem, rhs: MessageItem) -> Bool { lhs.id == rhs.id }
}
