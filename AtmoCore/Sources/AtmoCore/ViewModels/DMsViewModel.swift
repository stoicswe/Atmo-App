import Foundation
import ATProtoKit
import Observation

@Observable
@MainActor
public final class DMsViewModel {

    public private(set) var conversations: [ConversationItem] = []
    public private(set) var isLoading: Bool = false
    public private(set) var error: Error? = nil

    private let service: ATProtoService

    public init(service: ATProtoService) {
        self.service = service
    }

    public func load() async {
        guard let chat = service.atProtoChat else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let output = try await chat.listConversations(limit: 50)
            conversations = output.conversations.map { ConversationItem(convo: $0) }
            error = nil
        } catch {
            self.error = error
        }
    }
}

@Observable
@MainActor
public final class ConversationDetailViewModel {

    public private(set) var messages: [MessageItem] = []
    public private(set) var isLoading: Bool = false
    public private(set) var isSending: Bool = false
    public private(set) var error: Error? = nil
    private var cursor: String? = nil

    public let conversationID: String
    private let service: ATProtoService

    public init(conversationID: String, service: ATProtoService) {
        self.conversationID = conversationID
        self.service = service
    }

    public func load() async {
        guard let chat = service.atProtoChat else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let output = try await chat.getMessages(from: conversationID, limit: 50)
            messages = output.messages.compactMap { msg -> MessageItem? in
                guard case .messageView(let view) = msg else { return nil }
                return MessageItem(messageView: view)
            }.reversed()
            cursor = output.cursor
            error = nil
        } catch {
            self.error = error
        }
    }

    /// Burst grouping for timestamps: messages from the same sender within
    /// a minute of each other share one timestamp, shown under the burst's
    /// last message. A sender change or a gap over a minute ends the burst.
    public func showsTimestamp(at index: Int) -> Bool {
        Self.showsTimestamp(at: index, in: messages)
    }

    /// Pure decision core, exposed for the unit tests.
    nonisolated static func showsTimestamp(at index: Int, in messages: [MessageItem]) -> Bool {
        guard index >= 0, index < messages.count else { return true }
        guard index < messages.count - 1 else { return true }
        let current = messages[index]
        let next = messages[index + 1]
        if next.senderDID != current.senderDID { return true }
        return next.sentAt.timeIntervalSince(current.sentAt) > 60
    }

    public func sendMessage(text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let chat = service.atProtoChat else { return }
        isSending = true
        do {
            let messageInput = ChatBskyLexicon.Conversation.MessageInputDefinition(text: text)
            let result = try await chat.sendMessage(to: conversationID, message: messageInput)
            messages.append(MessageItem(messageView: result))
        } catch {
            self.error = error
        }
        isSending = false
    }
}
