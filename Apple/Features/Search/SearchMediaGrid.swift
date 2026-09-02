import SwiftUI
import AtmoCore
import ATProtoKit

// MARK: - Search Media Grid
// Bento-style grid for media-filtered post results: rows cycle through
// three patterns — a big tile with two small ones stacked beside it, three
// small tiles, and the mirror of the first — so the page reads as a
// mosaic rather than a uniform grid.
//   • Images: tap opens the full-screen viewer; long-press offers Go to
//     Post / Full Screen.
//   • Videos: never auto-play here. Tap plays or pauses; long-press
//     offers Go to Post / Full Screen.
//   • GIFs: play on their own (they're silent loops); tap goes to the post.
struct SearchMediaGrid: View {
    let posts: [PostItem]
    let onOpenPost: (PostItem) -> Void
    let onReachEnd: () -> Void

    private static let gap: CGFloat = 6
    /// Measured once; rows size themselves from it (a GeometryReader per
    /// row would collapse inside the lazy stack).
    @State private var width: CGFloat = 0

    var body: some View {
        LazyVStack(spacing: Self.gap) {
            if width > 0 {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    bentoRow(row, pattern: index % 3)
                        .onAppear {
                            if index >= rows.count - 1 { onReachEnd() }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Three posts per row.
    private var rows: [[PostItem]] {
        stride(from: 0, to: posts.count, by: 3).map { start in
            Array(posts[start..<min(start + 3, posts.count)])
        }
    }

    private var unit: CGFloat { (width - Self.gap * 2) / 3 }
    private var big: CGFloat { unit * 2 + Self.gap }

    @ViewBuilder
    private func bentoRow(_ row: [PostItem], pattern: Int) -> some View {
        HStack(alignment: .top, spacing: Self.gap) {
            switch (pattern, row.count) {
            case (0, 3):
                tile(row[0]).frame(width: big, height: big)
                VStack(spacing: Self.gap) {
                    tile(row[1]).frame(width: unit, height: unit)
                    tile(row[2]).frame(width: unit, height: unit)
                }
            case (2, 3):
                VStack(spacing: Self.gap) {
                    tile(row[0]).frame(width: unit, height: unit)
                    tile(row[1]).frame(width: unit, height: unit)
                }
                tile(row[2]).frame(width: big, height: big)
            default:
                ForEach(row) { post in
                    tile(post).frame(width: unit, height: unit)
                }
                if row.count < 3 { Spacer(minLength: 0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ post: PostItem) -> some View {
        MediaTile(post: post, onOpenPost: { onOpenPost(post) })
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Media Tile

private struct MediaTile: View {
    let post: PostItem
    let onOpenPost: () -> Void

    @Environment(ImageViewerPresenter.self) private var viewerPresenter: ImageViewerPresenter?
    @State private var showViewer = false
    @State private var viewerIndex = 0
    @State private var fullscreenRequest = 0

    /// Labeled sensitive and not yet revealed through the shield (which
    /// keys its reveal on the post URI).
    private var isShielded: Bool {
        post.hasSensitiveMediaLabel && !ContentRevealStore.shared.isRevealed(post.uri)
    }

    var body: some View {
        // Every kind of media is pinned to the tile's bounds BEFORE the
        // shield blurs it, so the blur can't spill out of the tile.
        Color.clear
            .overlay {
                switch post.media {
                case .images(let images):
                    imageTile(images)
                case .video(let video):
                    videoTile(video)
                case .gif(let link, let thumbnailURL, let title):
                    gifTile(link: link, thumbnailURL: thumbnailURL, title: title)
                case nil:
                    Color.secondary.opacity(0.1)
                }
            }
            .clipped()
            .sensitiveMediaShield(post.hasSensitiveMediaLabel, key: post.uri)
            .clipped()
            // Press and hold on ANY tile: Go to Post, plus Full Screen for
            // photos and videos. Attached to the tile itself so neither the
            // tap handling nor the shield can shadow it.
            .contextMenu {
                Button {
                    onOpenPost()
                } label: {
                    Label("Go to Post", systemImage: "text.bubble")
                }
                switch post.media {
                case .images(let images):
                    Button {
                        openViewer(images)
                    } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                case .video:
                    if !isShielded {
                        Button {
                            fullscreenRequest += 1
                        } label: {
                            Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                default:
                    EmptyView()
                }
            }
    }

    // MARK: Images — tap: full screen; hold: go to post / full screen

    private func imageTile(_ images: [AppBskyLexicon.Embed.ImagesDefinition.ViewImage]) -> some View {
        Color.clear
            .overlay {
                AsyncCachedImage(url: images[0].thumbnailImageURL, maxPixelSize: 900) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if images.count > 1 {
                    Image(systemName: "square.on.square.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(6)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { openViewer(images) }
            .sheet(isPresented: $showViewer) {
                ImageViewerView(images: images, selectedIndex: $viewerIndex)
            }
            .accessibilityLabel(images[0].altText.isEmpty ? "Image" : images[0].altText)
    }

    private func openViewer(_ images: [AppBskyLexicon.Embed.ImagesDefinition.ViewImage]) {
        Haptics.tap()
        if let viewerPresenter {
            viewerPresenter.present(images, at: 0, postURI: post.uri)
        } else {
            viewerIndex = 0
            showViewer = true
        }
    }

    // MARK: Videos — no autoplay; tap: play/pause; hold: go to post / full screen

    @ViewBuilder
    private func videoTile(_ video: AppBskyLexicon.Embed.VideoDefinition.View) -> some View {
        // Shielded: the still only — nothing plays behind a blur.
        if !isShielded, let playlistURL = URL(string: video.playlistURI) {
            Color.clear
                .overlay {
                    EmbeddedVideoPlayer(
                        playlistURL: playlistURL,
                        thumbnailURL: video.thumbnailImageURL.flatMap(URL.init(string:)),
                        autoplays: false,
                        tapTogglesPlayback: true,
                        fullscreenRequest: fullscreenRequest
                    )
                }
                .clipped()
            .accessibilityLabel(video.altText?.isEmpty == false ? "Video: \(video.altText!)" : "Video")
        } else {
            Color.clear
                .overlay {
                    if let thumbString = video.thumbnailImageURL, let thumbURL = URL(string: thumbString) {
                        AsyncCachedImage(url: thumbURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.black.opacity(0.4)
                            }
                        }
                    } else {
                        Color.black.opacity(0.4)
                    }
                }
                .clipped()
        }
    }

    // MARK: GIFs — autoplay; tap: go to post

    private func gifTile(link: GIFLink, thumbnailURL: URL?, title: String) -> some View {
        Color.clear
            .overlay {
                GIFEmbedView(link: link, thumbnailURL: thumbnailURL, altText: title) {
                    AsyncCachedImage(url: thumbnailURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                }
                // Fill the square tile rather than letterbox to the GIF's ratio.
                .aspectRatio(contentMode: .fill)
            }
            .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onOpenPost() })
    }
}
