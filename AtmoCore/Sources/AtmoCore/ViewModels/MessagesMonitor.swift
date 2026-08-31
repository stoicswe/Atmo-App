import Foundation
import Observation

// MARK: - Messages Cache
/// Session-wide cache of the conversation list. The Messages page seeds
/// from it instantly (no spinner after the first fill) and every fetch —
/// page loads and the background poll alike — writes back through it.
@Observable
@MainActor
public final class MessagesCache {
    public static let shared = MessagesCache()

    public internal(set) var conversations: [ConversationItem] = []
    /// Whether the cache has been filled at least once this session.
    public internal(set) var hasLoadedOnce = false

    private init() {}

    public func update(_ conversations: [ConversationItem]) {
        self.conversations = conversations
        self.hasLoadedOnce = true
    }
}

// MARK: - Messages Monitor
/// Background direct-message poll, independent of the Messages page being
/// open, on its own (shorter) interval than the timeline poll. Each pass
/// refreshes the shared cache and raises one notification per conversation
/// with a newly arrived incoming message.
@Observable
@MainActor
public final class MessagesMonitor {

    private let service: ATProtoService
    /// Baseline for arrival detection: convoID → the last message time
    /// already seen. The first successful fetch only records the baseline —
    /// it never notifies, so launching the app doesn't replay the inbox.
    private var lastSeenMessageAt: [String: Date] = [:]
    private var hasBaseline = false
    private var isFetching = false

    @ObservationIgnored nonisolated(unsafe) private var pollTask: Task<Void, Never>? = nil

    public init(service: ATProtoService) {
        self.service = service
        Task { @MainActor [weak self] in
            self?.startPolling()
        }
    }

    deinit {
        pollTask?.cancel()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        let interval = Atmo.platform.messagesRefreshInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(
                    for: .seconds(interval),
                    tolerance: .seconds(interval * 0.1)
                )
            }
        }
    }

    /// One poll pass: fetch the list, detect arrivals against the
    /// baseline, update the cache, notify.
    public func refresh() async {
        guard !isFetching, let chat = service.atProtoChat else { return }
        isFetching = true
        defer { isFetching = false }

        do {
            let output = try await chat.listConversations(limit: 50)
            let fresh = output.conversations.map { ConversationItem(convo: $0) }

            let incoming = Self.incomingConversations(
                fresh: fresh,
                lastSeen: hasBaseline ? lastSeenMessageAt : nil,
                currentUserDID: service.currentUserDID
            )

            MessagesCache.shared.update(fresh)
            for convo in fresh {
                if let at = convo.lastMessageAt {
                    lastSeenMessageAt[convo.convoID] = at
                }
            }
            hasBaseline = true

            if !incoming.isEmpty {
                _ = await Atmo.platform.alertPresenter.requestAuthorization()
                await Atmo.platform.alertPresenter.present(incoming.map(Self.alert(for:)))
            }
        } catch {
            // Silent — a background poll failure isn't worth surfacing.
        }
    }

    // MARK: Pure decision core (unit-tested)

    /// Conversations whose last message newly ARRIVED from someone else:
    /// unread, sent by another account, and newer than the baseline (or in
    /// a conversation the baseline has never seen). A nil baseline (first
    /// fetch of the session) never notifies.
    nonisolated static func incomingConversations(
        fresh: [ConversationItem],
        lastSeen: [String: Date]?,
        currentUserDID: String?
    ) -> [ConversationItem] {
        guard let lastSeen else { return [] }
        return fresh.filter { convo in
            guard let at = convo.lastMessageAt, convo.unreadCount > 0 else { return false }
            if let sender = convo.lastMessageSenderDID, let me = currentUserDID, sender == me {
                return false
            }
            if let seen = lastSeen[convo.convoID] {
                return at > seen
            }
            return true
        }
    }

    /// A notification for one newly arrived message, threaded per
    /// conversation and keyed so the same arrival never notifies twice.
    nonisolated static func alert(for convo: ConversationItem) -> FeedAlert {
        let sender = convo.participants.first { $0.did == convo.lastMessageSenderDID }
            ?? convo.participants.first
        let title = sender.map { $0.displayName ?? "@\($0.handle)" } ?? "New message"
        return FeedAlert(
            id: "dm.\(convo.convoID).\(convo.lastMessageAt?.timeIntervalSince1970 ?? 0)",
            title: title,
            body: convo.lastMessage ?? "Sent you a message",
            kind: .directMessage(conversationID: convo.convoID)
        )
    }
}
