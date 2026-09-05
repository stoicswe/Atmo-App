import Foundation
import ATProtoKit

/// A platform-neutral digest of a post's embed union — the displayable
/// facts (image URLs, link card, quoted post) without ATProtoKit's nested
/// unions. The SwiftUI app renders the raw union directly (it needs the
/// full fidelity — carousels, video players, viewers); simpler front ends
/// like the GTK app render from this.
public struct EmbedContent: Hashable, Sendable {

    public struct ImageItem: Hashable, Sendable {
        public let thumbnailURL: URL
        public let fullSizeURL: URL?
        public let altText: String

        public init(thumbnailURL: URL, fullSizeURL: URL?, altText: String) {
            self.thumbnailURL = thumbnailURL
            self.fullSizeURL = fullSizeURL
            self.altText = altText
        }
    }

    public struct ExternalLink: Hashable, Sendable {
        public let uri: String
        public let title: String
        public let linkDescription: String
        /// The site's social-card image, when the loader supplied one.
        public let thumbnailURL: URL?

        public init(uri: String, title: String, linkDescription: String, thumbnailURL: URL? = nil) {
            self.uri = uri
            self.title = title
            self.linkDescription = linkDescription
            self.thumbnailURL = thumbnailURL
        }

        /// The site's host, for the compact "title — host" treatment.
        public var host: String {
            URL(string: uri)?.host ?? uri
        }
    }

    public struct Quote: Hashable, Sendable {
        public let uri: String
        public let authorHandle: String
        public let authorDisplayName: String?
        public let text: String

        public init(uri: String, authorHandle: String, authorDisplayName: String?, text: String) {
            self.uri = uri
            self.authorHandle = authorHandle
            self.authorDisplayName = authorDisplayName
            self.text = text
        }
    }

    public struct Video: Hashable, Sendable {
        /// The HLS playlist (`.m3u8`) the video streams from.
        public let playlistURL: URL?
        public let thumbnailURL: URL?
        public let altText: String?
        /// Native pixel size when the server supplied one — front ends
        /// derive the player box's aspect ratio from it.
        public let width: Int?
        public let height: Int?

        public init(playlistURL: URL?, thumbnailURL: URL?, altText: String?, width: Int?, height: Int?) {
            self.playlistURL = playlistURL
            self.thumbnailURL = thumbnailURL
            self.altText = altText
            self.width = width
            self.height = height
        }
    }

    public var images: [ImageItem] = []
    public var externalLink: ExternalLink? = nil
    public var quote: Quote? = nil
    public var video: Video? = nil

    /// Kept for front ends that only need the fact, not the stream.
    public var hasVideo: Bool { video != nil }

    public var isEmpty: Bool {
        images.isEmpty && externalLink == nil && quote == nil && video == nil
    }

    public init() {}
}

extension PostItem {

    /// The post's embed digested for display; nil when there is no embed
    /// or nothing in it is renderable.
    public var embedContent: EmbedContent? {
        guard let embed else { return nil }
        var content = EmbedContent()

        switch embed {
        case .embedImagesView(let view):
            content.images = view.images.map(EmbedContent.ImageItem.init(viewImage:))

        case .embedVideoView(let view):
            content.video = EmbedContent.Video(view: view)

        case .embedExternalView(let view):
            content.externalLink = EmbedContent.ExternalLink(viewExternal: view.external)

        case .embedRecordView(let view):
            content.quote = EmbedContent.Quote(record: view.record)

        case .embedRecordWithMediaView(let view):
            switch view.media {
            case .embedImagesView(let images):
                content.images = images.images.map(EmbedContent.ImageItem.init(viewImage:))
            case .embedVideoView(let video):
                content.video = EmbedContent.Video(view: video)
            case .embedExternalView(let external):
                content.externalLink = EmbedContent.ExternalLink(viewExternal: external.external)
            default:
                break
            }
            content.quote = EmbedContent.Quote(record: view.record.record)

        default:
            break
        }

        return content.isEmpty ? nil : content
    }
}

extension EmbedContent.ImageItem {
    init(viewImage: AppBskyLexicon.Embed.ImagesDefinition.ViewImage) {
        self.init(
            thumbnailURL: viewImage.thumbnailImageURL,
            fullSizeURL: viewImage.fullSizeImageURL,
            altText: viewImage.altText
        )
    }
}

extension EmbedContent.ExternalLink {
    init(viewExternal: AppBskyLexicon.Embed.ExternalDefinition.ViewExternal) {
        self.init(
            uri: viewExternal.uri,
            title: viewExternal.title,
            linkDescription: viewExternal.description,
            thumbnailURL: viewExternal.thumbnailImageURL
        )
    }
}

extension EmbedContent.Video {
    init(view: AppBskyLexicon.Embed.VideoDefinition.View) {
        self.init(
            playlistURL: URL(string: view.playlistURI),
            thumbnailURL: view.thumbnailImageURL.flatMap(URL.init(string:)),
            altText: view.altText,
            width: view.aspectRatio?.width,
            height: view.aspectRatio?.height
        )
    }
}

extension EmbedContent.Quote {
    /// nil for blocked/deleted/non-post records — the union's other cases.
    init?(record: AppBskyLexicon.Embed.RecordDefinition.View.RecordViewUnion) {
        guard case .viewRecord(let viewRecord) = record else { return nil }
        self.init(
            uri: viewRecord.uri,
            authorHandle: viewRecord.author.actorHandle,
            authorDisplayName: viewRecord.author.displayName,
            text: viewRecord.value.getRecord(ofType: AppBskyLexicon.Feed.PostRecord.self)?.text ?? ""
        )
    }
}
