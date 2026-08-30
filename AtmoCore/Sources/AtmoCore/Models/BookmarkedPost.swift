import Foundation

// Lightweight Codable snapshot of a post stored locally and synced via the
// platform's synced key-value store. Only stores what's needed to render
// the bookmark list row and navigate to the thread.
public struct BookmarkedPost: Codable, Identifiable, Equatable, Sendable {
    public let id: String          // == uri, canonical identity
    public let uri: String
    public let cid: String
    public let authorDID: String
    public let authorHandle: String
    public let authorDisplayName: String?
    public let authorAvatarURLString: String?
    public let text: String
    public let indexedAt: Date
    public let bookmarkedAt: Date

    public var authorAvatarURL: URL? {
        authorAvatarURLString.flatMap { URL(string: $0) }
    }

    // Build from a live PostItem
    public init(post: PostItem) {
        self.id             = post.uri
        self.uri            = post.uri
        self.cid            = post.cid
        self.authorDID      = post.authorDID
        self.authorHandle   = post.authorHandle
        self.authorDisplayName = post.authorDisplayName
        self.authorAvatarURLString = post.authorAvatarURL?.absoluteString
        self.text           = post.text
        self.indexedAt      = post.indexedAt
        self.bookmarkedAt   = Date()
    }
}
