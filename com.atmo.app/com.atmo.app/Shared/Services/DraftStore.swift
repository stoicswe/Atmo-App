import Foundation
import Observation

// MARK: - DraftPost
// A single post slot in a thread draft.
struct DraftPost: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var attachedImageFileNames: [String]  // stored separately; full data not persisted to keep size small

    init(id: UUID = UUID(), text: String = "", attachedImageFileNames: [String] = []) {
        self.id = id
        self.text = text
        self.attachedImageFileNames = attachedImageFileNames
    }
}

// MARK: - ComposerDraft
// Full snapshot of a composer session: one or more posts forming a thread.
struct ComposerDraft: Codable, Identifiable, Equatable {
    var id: UUID
    /// The posts in thread order. Always has at least 1 element.
    var posts: [DraftPost]
    /// URI of the post being replied to, if any.
    var replyToURI: String?
    /// URI of the post being quoted, if any.
    var quotedPostURI: String?
    /// When the draft was last modified.
    var modifiedAt: Date

    var isEmpty: Bool {
        posts.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    init(
        id: UUID = UUID(),
        posts: [DraftPost] = [DraftPost()],
        replyToURI: String? = nil,
        quotedPostURI: String? = nil,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.posts = posts
        self.replyToURI = replyToURI
        self.quotedPostURI = quotedPostURI
        self.modifiedAt = modifiedAt
    }
}

// MARK: - DraftStore
// Persists composer drafts to UserDefaults so they survive app termination.
//
// Usage:
//   DraftStore.shared.save(draft)            // upsert
//   DraftStore.shared.delete(id: draft.id)  // remove after posting
//   DraftStore.shared.drafts                 // all drafts, newest first
@Observable
@MainActor
final class DraftStore {

    static let shared = DraftStore()

    private(set) var drafts: [ComposerDraft] = []

    private let storeKey = "com.atmo.app.composerDrafts"

    private init() {
        load()
    }

    // MARK: - Public API

    /// Inserts or updates a draft. Call whenever the user edits the composer.
    func save(_ draft: ComposerDraft) {
        var updated = draft
        updated.modifiedAt = Date()
        if let idx = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[idx] = updated
        } else {
            drafts.insert(updated, at: 0)
        }
        persist()
    }

    /// Removes a draft by ID. Call after successful post submission.
    func delete(id: UUID) {
        drafts.removeAll { $0.id == id }
        persist()
    }

    /// Returns the most-recently modified non-empty draft that matches
    /// the given reply/quote context (or a root draft when both are nil).
    /// Used to restore an interrupted session.
    func latestDraft(replyToURI: String?, quotedPostURI: String?) -> ComposerDraft? {
        drafts.first {
            !$0.isEmpty
            && $0.replyToURI == replyToURI
            && $0.quotedPostURI == quotedPostURI
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        drafts = (try? decoder.decode([ComposerDraft].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
