import Foundation
import ATProtoKit

struct MessageItem: Identifiable, Hashable {
    let id: String  // == messageID
    let messageID: String
    let senderDID: String
    let text: String
    let sentAt: Date

    init(messageView: ChatBskyLexicon.Conversation.MessageViewDefinition) {
        self.messageID = messageView.messageID
        self.id = messageView.messageID
        self.senderDID = messageView.sender.authorDID
        self.text = messageView.text
        self.sentAt = messageView.sentAt
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MessageItem, rhs: MessageItem) -> Bool { lhs.id == rhs.id }
}
