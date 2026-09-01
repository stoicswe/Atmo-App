import Foundation
import ATProtoKit

public struct ConversationItem: Identifiable, Hashable, Sendable {
    public let id: String  // == convoID
    public let convoID: String
    public let participants: [ParticipantInfo]
    public let lastMessage: String?
    public let lastMessageAt: Date?
    /// DID of whoever sent the last message — lets the DM poller tell an
    /// incoming message from the user's own.
    public let lastMessageSenderDID: String?
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
            self.lastMessage = MessageItem.previewText(text: view.text, hasEmbed: view.embed != nil)
            self.lastMessageAt = view.sentAt
            self.lastMessageSenderDID = view.sender.authorDID
        } else {
            self.lastMessage = nil
            self.lastMessageAt = nil
            self.lastMessageSenderDID = nil
        }
        self.unreadCount = convo.unreadCount
    }

    /// Internal fixture initializer for unit tests.
    init(
        testID: String,
        participants: [ParticipantInfo] = [],
        lastMessage: String? = nil,
        lastMessageAt: Date? = nil,
        lastMessageSenderDID: String? = nil,
        unreadCount: Int = 0
    ) {
        self.id = testID
        self.convoID = testID
        self.participants = participants
        self.lastMessage = lastMessage
        self.lastMessageAt = lastMessageAt
        self.lastMessageSenderDID = lastMessageSenderDID
        self.unreadCount = unreadCount
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: ConversationItem, rhs: ConversationItem) -> Bool { lhs.id == rhs.id }
}
