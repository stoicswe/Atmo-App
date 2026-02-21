import Foundation
import ATProtoKit

struct ConversationItem: Identifiable, Hashable {
    let id: String  // == convoID
    let convoID: String
    let participants: [ParticipantInfo]
    let lastMessage: String?
    let lastMessageAt: Date?
    let unreadCount: Int

    struct ParticipantInfo: Hashable {
        let did: String
        let handle: String
        let displayName: String?
        let avatarURL: URL?
    }

    init(convo: ChatBskyLexicon.Conversation.ConversationViewDefinition) {
        self.convoID = convo.conversationID
        self.id = convo.conversationID
        self.participants = convo.members.map { member in
            ParticipantInfo(
                did: member.actorDID,
                handle: member.actorHandle,
                displayName: member.displayName,
                avatarURL: member.avatarImageURL
            )
        }
        // Extract last message text
        if let lastMsg = convo.lastMessage,
           case .messageView(let view) = lastMsg {
            self.lastMessage = view.text
            self.lastMessageAt = view.sentAt
        } else {
            self.lastMessage = nil
            self.lastMessageAt = nil
        }
        self.unreadCount = convo.unreadCount
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ConversationItem, rhs: ConversationItem) -> Bool { lhs.id == rhs.id }
}
