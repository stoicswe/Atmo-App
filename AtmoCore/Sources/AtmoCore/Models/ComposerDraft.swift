import Foundation

// MARK: - Draft Media References
// Drafts keep their media as REFERENCES: image bytes live as files in
// the composer media directory (ComposerMediaFiles) keyed by attachment
// id; video/memo references point at the composer-owned media file that
// was created at attach time. The draft JSON stays small either way.

/// One image attachment persisted with a draft.
public struct DraftImageRef: Codable, Identifiable, Equatable, Sendable {
    /// Keys the image's data file in the composer media directory.
    public var id: UUID
    /// Upload filename.
    public var fileName: String
    public var altText: String

    public init(id: UUID, fileName: String, altText: String = "") {
        self.id = id
        self.fileName = fileName
        self.altText = altText
    }
}

/// A video or voice-memo reference persisted with a draft.
public struct DraftVideoRef: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case video
        case voiceMemo
    }

    public var kind: Kind
    /// Absolute path of the composer-owned media file.
    public var filePath: String
    public var duration: TimeInterval?
    public var aspectWidth: Int?
    public var aspectHeight: Int?
    public var altText: String

    public init(
        kind: Kind,
        filePath: String,
        duration: TimeInterval? = nil,
        aspectWidth: Int? = nil,
        aspectHeight: Int? = nil,
        altText: String = ""
    ) {
        self.kind = kind
        self.filePath = filePath
        self.duration = duration
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
        self.altText = altText
    }
}

// MARK: - DraftPost
// A single post slot in a thread draft.
public struct DraftPost: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    /// Legacy field from the era when drafts kept names only — retained
    /// so old persisted drafts keep decoding.
    public var attachedImageFileNames: [String]
    /// Image attachments (data files keyed by ref id).
    public var images: [DraftImageRef]
    /// Video or voice-memo attachment.
    public var video: DraftVideoRef?

    public var hasMedia: Bool {
        !images.isEmpty || video != nil
    }

    public init(
        id: UUID = UUID(),
        text: String = "",
        attachedImageFileNames: [String] = [],
        images: [DraftImageRef] = [],
        video: DraftVideoRef? = nil
    ) {
        self.id = id
        self.text = text
        self.attachedImageFileNames = attachedImageFileNames
        self.images = images
        self.video = video
    }

    // Manual decoding: drafts saved before media persistence lack the new
    // keys and must keep decoding.
    enum CodingKeys: String, CodingKey {
        case id, text, attachedImageFileNames, images, video
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        attachedImageFileNames = try container.decodeIfPresent([String].self, forKey: .attachedImageFileNames) ?? []
        images = try container.decodeIfPresent([DraftImageRef].self, forKey: .images) ?? []
        video = try container.decodeIfPresent(DraftVideoRef.self, forKey: .video)
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

    /// Nothing worth keeping: no typed text and no media.
    public var isEmpty: Bool {
        posts.allSatisfy {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasMedia
        }
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
