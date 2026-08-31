import Foundation
import ATProtoKit
import Observation

/// Recipient picker for starting a DM: suggests the user's follows —
/// mutuals first — and searches the network, keeping only accounts whose
/// chat settings accept a message from this user.
@Observable
@MainActor
public final class NewConversationViewModel {

    /// A candidate DM recipient.
    public struct Candidate: Identifiable, Hashable, Sendable {
        public let id: String   // == did
        public let did: String
        public let handle: String
        public let displayName: String?
        public let avatarURL: URL?
        /// Both sides follow each other.
        public let isMutual: Bool

        init(profile: AppBskyLexicon.Actor.ProfileViewDefinition) {
            self.did = profile.actorDID
            self.id = profile.actorDID
            self.handle = profile.actorHandle
            self.displayName = profile.displayName
            self.avatarURL = profile.avatarImageURL
            self.isMutual = profile.viewer?.followedByURI != nil
        }
    }

    /// The user's follows, mutuals first (original follow order within each
    /// group), filtered to people who can be messaged.
    public private(set) var suggestions: [Candidate] = []
    public private(set) var searchResults: [Candidate] = []
    public private(set) var isLoading = false
    public private(set) var error: Error? = nil

    private let service: ATProtoService
    @ObservationIgnored nonisolated(unsafe) private var searchTask: Task<Void, Never>? = nil

    public init(service: ATProtoService) {
        self.service = service
    }

    deinit { searchTask?.cancel() }

    /// Whether a profile's chat declaration lets this user message them.
    /// A missing declaration means "following" per the protocol default,
    /// and "following" requires that THEY follow the current user.
    nonisolated static func canReceiveDMs(allowIncoming: String?, theyFollowMe: Bool) -> Bool {
        switch allowIncoming ?? "following" {
        case "all":  return true
        case "none": return false
        default:     return theyFollowMe
        }
    }

    public func loadSuggestions() async {
        guard suggestions.isEmpty, !isLoading,
              let kit = service.atProtoKit,
              let did = service.currentUserDID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let output = try await kit.getFollows(from: did, limit: 100)
            let candidates = output.follows
                .filter {
                    Self.canReceiveDMs(
                        allowIncoming: $0.associated?.chats?.allowIncoming,
                        theyFollowMe: $0.viewer?.followedByURI != nil
                    )
                }
                .map(Candidate.init)
            suggestions = candidates.filter(\.isMutual) + candidates.filter { !$0.isMutual }
            error = nil
        } catch {
            self.error = error
        }
    }

    /// Debounced network actor search (300 ms after the last keystroke).
    public func onQueryChanged(_ newValue: String) {
        searchTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.search(trimmed)
        }
    }

    private func search(_ query: String) async {
        guard let kit = service.atProtoKit else { return }
        do {
            let output = try await kit.searchActors(matching: query, limit: 25)
            guard !Task.isCancelled else { return }
            searchResults = output.actors
                .filter {
                    Self.canReceiveDMs(
                        allowIncoming: $0.associated?.chats?.allowIncoming,
                        theyFollowMe: $0.viewer?.followedByURI != nil
                    )
                }
                .map(Candidate.init)
        } catch {
            // Quiet — the user is mid-typing; stale results simply remain.
        }
    }

    /// Opens (or creates) the 1:1 conversation with this person.
    public func openConversation(with did: String) async -> ConversationItem? {
        guard let chat = service.atProtoChat else { return nil }
        do {
            let output = try await chat.getConversaionForMembers([did])
            return ConversationItem(convo: output.conversation)
        } catch {
            self.error = error
            return nil
        }
    }
}
