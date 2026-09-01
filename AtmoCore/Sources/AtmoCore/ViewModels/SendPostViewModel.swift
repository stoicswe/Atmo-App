import Foundation
import ATProtoKit
import Observation

// MARK: - Send Post View Model
/// "Send post in a message": picks a recipient — a recent conversation,
/// or a person from the same follows-and-search pool a new message uses —
/// and sends the post as a record embed, the way the official client
/// shares a post into chat. Progress is tracked per recipient so the
/// sheet can show Send → sending → Sent on each row and the person can
/// send the same post to several people in one go.
@Observable
@MainActor
public final class SendPostViewModel {

    public enum SendState: Sendable, Equatable {
        case idle, sending, sent, failed
    }

    public let post: PostItem
    /// Recent conversations, newest first (session cache first, then the
    /// server's list once it arrives).
    public private(set) var conversations: [ConversationItem] = []
    public private(set) var isLoadingConversations = false
    /// People the post can be sent to: follows (mutuals first) and search.
    public let people: NewConversationViewModel
    /// Progress keyed by conversation ID (recent rows) or DID (people rows).
    public private(set) var states: [String: SendState] = [:]
    public private(set) var error: Error? = nil

    private let service: ATProtoService

    public init(post: PostItem, service: ATProtoService) {
        self.post = post
        self.service = service
        self.people = NewConversationViewModel(service: service)
        self.conversations = MessagesCache.shared.conversations
    }

    public var currentUserDID: String? { service.currentUserDID }

    public func state(for key: String) -> SendState {
        states[key] ?? .idle
    }

    /// Loads recent conversations and the follow suggestions together.
    public func load() async {
        async let convos: Void = loadConversations()
        async let follows: Void = people.loadSuggestions()
        _ = await (convos, follows)
    }

    private func loadConversations() async {
        guard let chat = service.atProtoChat else { return }
        isLoadingConversations = true
        defer { isLoadingConversations = false }
        do {
            let output = try await chat.listConversations(limit: 50)
            conversations = output.conversations.map { ConversationItem(convo: $0) }
            MessagesCache.shared.update(conversations)
        } catch {
            self.error = error
        }
    }

    public func onQueryChanged(_ query: String) {
        people.onQueryChanged(query)
    }

    /// Sends into an existing conversation.
    public func send(toConversation conversation: ConversationItem) async {
        await send(key: conversation.convoID, conversationID: conversation.convoID)
    }

    /// Opens (or creates) the 1:1 conversation with `did`, then sends.
    public func send(toPerson did: String) async {
        guard Self.canStart(state(for: did)) else { return }
        states[did] = .sending
        guard let conversation = await people.openConversation(with: did) else {
            states[did] = .failed
            error = people.error
            return
        }
        await send(key: did, conversationID: conversation.convoID)
    }

    private func send(key: String, conversationID: String) async {
        guard Self.canStart(state(for: key)) || states[key] == .sending else { return }
        guard let chat = service.atProtoChat,
              let input = ConversationDetailViewModel.messageInput(text: "", embeddedPost: post)
        else {
            states[key] = .failed
            return
        }
        states[key] = .sending
        do {
            _ = try await chat.sendMessage(to: conversationID, message: input)
            states[key] = .sent
            error = nil
        } catch {
            states[key] = .failed
            self.error = error
        }
    }

    /// A row may start (or retry) a send unless one is in flight or done.
    public nonisolated static func canStart(_ state: SendState) -> Bool {
        state == .idle || state == .failed
    }
}
