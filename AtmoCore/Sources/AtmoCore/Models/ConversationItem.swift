import Foundation
import ATProtoKit

public struct ConversationItem: Identifiable, Hashable, Sendable {
    public let id: String  // == convoID
    public let convoID: String
    public let participants: [ParticipantInfo]
    public let lastMessage: String?
    public let lastMessageAt: Date?
    public let unreadCount: Int

    public struct ParticipantInfo: Hashable, Sendable {
        public let did: String
        public let handle: String
        public let displayName: String?
        public let avatarURL: URL?
    }

    public init(convo: ChatBskyLexicon.Conversation.ConversationViewDefinition) {
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

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: ConversationItem, rhs: ConversationItem) -> Bool { lhs.id == rhs.id }
}
