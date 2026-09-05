import Foundation
import ATProtoKit

// MARK: - Post Media
/// What a post's embed carries, media-wise — the grid tiles are built
/// from this rather than from the raw embed union.
public enum PostMedia: Sendable {
    case images([AppBskyLexicon.Embed.ImagesDefinition.ViewImage])
    case video(AppBskyLexicon.Embed.VideoDefinition.View)
    case gif(link: GIFLink, thumbnailURL: URL?, title: String)

    public var kind: MediaFilter {
        switch self {
        case .images: return .images
        case .video:  return .videos
        case .gif:    return .gifs
        }
    }
}

// MARK: - Media Filter
/// The post-results filter: everything, or only posts carrying images,
/// videos, or GIFs (link embeds pointing at a GIF).
public enum MediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all, images, videos, gifs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all:    return "All"
        case .images: return "Images"
        case .videos: return "Videos"
        case .gifs:   return "GIFs"
        }
    }

    public var icon: String {
        switch self {
        case .all:    return "text.bubble"
        case .images: return "photo.on.rectangle"
        case .videos: return "play.rectangle"
        case .gifs:   return "play.square.stack"
        }
    }

    /// Whether the post belongs under this filter.
    public func matches(_ post: PostItem) -> Bool {
        switch self {
        case .all: return true
        default:   return post.media?.kind == self
        }
    }

    /// The posts this filter keeps, in their original order.
    public func apply(_ posts: [PostItem]) -> [PostItem] {
        self == .all ? posts : posts.filter(matches)
    }
}

public extension PostItem {
    /// The post's own media (top-level embed, or the media half of a
    /// quote-with-media). Quoted posts' media doesn't count — it isn't
    /// this post's.
    var media: PostMedia? {
        guard let embed else { return nil }
        switch embed {
        case .embedImagesView(let images):
            return images.images.isEmpty ? nil : .images(images.images)
        case .embedVideoView(let video):
            return .video(video)
        case .embedExternalView(let external):
            return Self.gifMedia(from: external.external)
        case .embedRecordWithMediaView(let rwm):
            switch rwm.media {
            case .embedImagesView(let images):
                return images.images.isEmpty ? nil : .images(images.images)
            case .embedVideoView(let video):
                return .video(video)
            case .embedExternalView(let external):
                return Self.gifMedia(from: external.external)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func gifMedia(from external: AppBskyLexicon.Embed.ExternalDefinition.ViewExternal) -> PostMedia? {
        guard let link = GIFLink.parse(external.uri) else { return nil }
        return .gif(link: link, thumbnailURL: external.thumbnailImageURL, title: external.title)
    }
}
