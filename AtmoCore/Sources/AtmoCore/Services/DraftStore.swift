import Foundation
import Observation

// MARK: - DraftStore
// Persists composer drafts to UserDefaults so they survive app termination.
//
// Usage:
//   DraftStore.shared.save(draft)            // upsert
//   DraftStore.shared.delete(id: draft.id)  // remove after posting
//   DraftStore.shared.drafts                 // all drafts, newest first
@Observable
@MainActor
public final class DraftStore {

    public static let shared = DraftStore()

    public private(set) var drafts: [ComposerDraft] = []

    private let storeKey = "com.atmo.app.composerDrafts"
    private let defaults: UserDefaults

    /// The designated initializer is internal so tests can point the store
    /// at a scratch `UserDefaults` suite; the app uses `.shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        // Composer media files whose draft is long gone (crashes, killed
        // sessions) get swept — everything still referenced survives.
        ComposerMediaFiles.pruneOrphans(referencedPaths: referencedMediaPaths())
    }

    /// Every media file path any current draft references.
    private func referencedMediaPaths() -> Set<String> {
        var paths = Set<String>()
        for draft in drafts {
            for post in draft.posts {
                for image in post.images {
                    paths.insert(ComposerMediaFiles.imageURL(for: image.id).path)
                }
                if let video = post.video {
                    paths.insert(video.filePath)
                }
            }
        }
        return paths
    }

    // MARK: - Public API

    /// Inserts or updates a draft. Call whenever the user edits the composer.
    public func save(_ draft: ComposerDraft) {
        var updated = draft
        updated.modifiedAt = Date()
        if let idx = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[idx] = updated
        } else {
            drafts.insert(updated, at: 0)
        }
        persist()
    }

    /// Removes a draft by ID (and its media files). Call after successful
    /// post submission or user deletion.
    ///
    /// `preservingVideoFile`: the submit path discards the draft BEFORE
    /// PostPublisher processes the referenced video file — the publisher
    /// owns that file's cleanup, so submission must not delete it here.
    /// (Draft image files are always safe to remove: the publish payload
    /// carries the image bytes in memory.)
    public func delete(id: UUID, preservingVideoFile: Bool = false) {
        if let draft = drafts.first(where: { $0.id == id }) {
            for post in draft.posts {
                for image in post.images {
                    ComposerMediaFiles.deleteImage(id: image.id)
                }
                if !preservingVideoFile, let video = post.video {
                    ComposerMediaFiles.delete(path: video.filePath)
                }
            }
        }
        drafts.removeAll { $0.id == id }
        persist()
    }

    /// Returns the most-recently modified non-empty draft that matches
    /// the given reply/quote context (or a root draft when both are nil).
    /// Used to restore an interrupted session.
    public func latestDraft(replyToURI: String?, quotedPostURI: String?) -> ComposerDraft? {
        drafts.first {
            !$0.isEmpty
            && $0.replyToURI == replyToURI
            && $0.quotedPostURI == quotedPostURI
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storeKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        drafts = (try? decoder.decode([ComposerDraft].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(drafts) else { return }
        defaults.set(data, forKey: storeKey)
    }
}
