import Foundation
import ATProtoKit
import Observation

@Observable
@MainActor
final class DMsViewModel {

    private(set) var conversations: [ConversationItem] = []
    private(set) var isLoading: Bool = false
    private(set) var error: Error? = nil

    private let service: ATProtoService

    init(service: ATProtoService) {
        self.service = service
    }

    func load() async {
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
final class ConversationDetailViewModel {

    private(set) var messages: [MessageItem] = []
    private(set) var isLoading: Bool = false
    private(set) var isSending: Bool = false
    private(set) var error: Error? = nil
    private var cursor: String? = nil

    let conversationID: String
    private let service: ATProtoService

    init(conversationID: String, service: ATProtoService) {
        self.conversationID = conversationID
        self.service = service
    }

    func load() async {
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

    func sendMessage(text: String) async {
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
