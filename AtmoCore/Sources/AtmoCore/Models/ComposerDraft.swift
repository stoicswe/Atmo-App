import Foundation

// MARK: - DraftPost
// A single post slot in a thread draft.
public struct DraftPost: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var attachedImageFileNames: [String]  // stored separately; full data not persisted to keep size small

    public init(id: UUID = UUID(), text: String = "", attachedImageFileNames: [String] = []) {
        self.id = id
        self.text = text
        self.attachedImageFileNames = attachedImageFileNames
    }
}

// MARK: - ComposerDraft
// Full snapshot of a composer session: one or more posts forming a thread.
public struct ComposerDraft: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The posts in thread order. Always has at least 1 element.
    public var posts: [DraftPost]
    /// URI of the post being replied to, if any.
    public var replyToURI: String?
    /// URI of the post being quoted, if any.
    public var quotedPostURI: String?
    /// When the draft was last modified.
    public var modifiedAt: Date

    public var isEmpty: Bool {
        posts.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public init(
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
