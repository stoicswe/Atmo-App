import SwiftUI
import AtmoCore
import ATProtoKit

/// Renders the embed attached to a post: images, external links, record quotes, etc.
///
/// - `onImageTap`: Optional callback invoked when the user taps an image.
///   Receives `(images, tappedIndex)` so the caller can present `ImageViewerView`
///   itself (ThreadView centralizes one viewer for all rows). When nil, images
///   are still tappable — the media view presents its own viewer.
struct PostEmbedView: View {
    let embed: AppBskyLexicon.Feed.PostViewDefinition.EmbedUnion
    /// Called with the full image array and the tapped index so the parent can
    /// present ImageViewerView. Pass nil to keep images non-interactive (timeline).
    var onImageTap: (([AppBskyLexicon.Embed.ImagesDefinition.ViewImage], Int) -> Void)? = nil
    /// Whether the owning post's media is labeled explicit — drives the
    /// Show/Blur/Hide shield on images and video.
    var sensitiveMedia: Bool = false
    /// The owning post, so an Enhanced image in the viewer can be kept
    /// with the post's bookmark (or Vault entry).
    var postURI: String? = nil

    var body: some View {
        Group {
            switch embed {
            case .embedImagesView(let images):
                ImageGridView(images: images.images, onImageTap: onImageTap, sensitiveMedia: sensitiveMedia, postURI: postURI)

            case .embedExternalView(let external):
                ExternalLinkCardView(external: external.external, sensitiveMedia: sensitiveMedia)

            case .embedRecordView(let record):
                if case .viewRecord(let viewRecord) = record.record {
                    QuotePostView(record: viewRecord)
                }

            case .embedRecordWithMediaView(let rwm):
                VStack(spacing: AtmoTheme.Spacing.sm) {
                    switch rwm.media {
                    case .embedImagesView(let images):
                        ImageGridView(images: images.images, onImageTap: onImageTap, sensitiveMedia: sensitiveMedia, postURI: postURI)
                    case .embedVideoView(let video):
                        VideoEmbedView(video: video, sensitiveMedia: sensitiveMedia)
                    case .embedExternalView(let external):
                        ExternalLinkCardView(external: external.external, sensitiveMedia: sensitiveMedia)
                    default:
                        EmptyView()
                    }
                    if case .viewRecord(let viewRecord) = rwm.record.record {
                        QuotePostView(record: viewRecord)
                    }
                }

            case .embedVideoView(let video):
                VideoEmbedView(video: video, sensitiveMedia: sensitiveMedia)

            default:
                EmptyView()
            }
        }
        // Each sub-view (ImageGridView, ExternalLinkCardView, etc.) applies its
        // own clipShape. Applying a second clip here on the unsized Group can
        // collapse embedded images to zero height on first layout in LazyVStack.
    }
}

// MARK: - Image Grid
// Internal (not private): ThreadReaderView reuses `displayAspectRatio` for
// its inline article images.
struct ImageGridView: View {
    let images: [AppBskyLexicon.Embed.ImagesDefinition.ViewImage]
    /// When non-nil, tapping an image calls this with (allImages, tappedIndex).
    /// When nil, this view presents its own ImageViewerView.
    var onImageTap: (([AppBskyLexicon.Embed.ImagesDefinition.ViewImage], Int) -> Void)? = nil
    /// Labeled explicit by Bluesky (author self-label or labeler).
    var sensitiveMedia: Bool = false
    /// Owning post, handed to the viewer for Enhanced-image retention.
    var postURI: String? = nil

    /// Flagged by on-device analysis (Apple's Sensitive Content Warning)
    /// when the post carried no label.
    @State private var screenerFlagged = false

    /// Carousel page currently snapped into view (drives the dots).
    @State private var carouselPage: Int? = 0
    /// Window-level glass viewer, mounted by the app root (and by sheets
    /// that host their own). Preferred over the sheet fallback below.
    @Environment(ImageViewerPresenter.self) private var viewerPresenter: ImageViewerPresenter?
    /// Fallback viewer state, used when no onImageTap delegate is provided
    /// and no glass-viewer host sits above this view.
    @State private var showViewer = false
    @State private var viewerIndex = 0

    var body: some View {
        let count = images.count
        Group {
            if count == 1 {
                // The box is sized from the API-provided aspect ratio BEFORE
                // the image loads, so the row never changes height when the
                // download lands — mid-scroll height shifts are what made the
                // feed feel jumpy. The ratio is clamped so very tall images
                // crop (like other clients) instead of dominating the feed.
                Color.clear
                    .aspectRatio(Self.displayAspectRatio(images[0].aspectRatio), contentMode: .fit)
                    .overlay {
                        // The 1000 px thumbnail preset, decoded to ~2× the
                        // widest cell: a quarter of the bytes and a tenth of
                        // the pixels of feed_fullsize, which is for the
                        // viewer only.
                        AsyncCachedImage(url: images[0].thumbnailImageURL, maxPixelSize: 1400) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.2)
                            }
                        }
                    }
                    .frame(maxHeight: 480)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap(0) }
                    // Subtle "tap to expand" affordance
                    .overlay(alignment: .bottomTrailing) { expandBadge }
            } else {
                carousel(count: count)
            }
        }
        .sensitiveMediaShield(sensitiveMedia || screenerFlagged, key: images.first?.thumbnailImageURL.absoluteString)
        .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
        .sheet(isPresented: $showViewer) {
            ImageViewerView(images: images, selectedIndex: $viewerIndex)
        }
        // Unlabeled images get the same on-device screening iMessage uses,
        // when the person has Sensitive Content Warning enabled.
        .task(id: images.first?.thumbnailImageURL) {
            guard !sensitiveMedia,
                  SensitiveMediaPolicy.currentEffectiveStored() != .show,
                  SensitiveImageScreener.isAvailable
            else { return }
            for image in images {
                if await SensitiveImageScreener.isSensitive(imageAt: image.thumbnailImageURL) {
                    screenerFlagged = true
                    break
                }
            }
        }
    }

    // MARK: Multi-image carousel
    // One full-width page per image, snapping page by page (like X/Bluesky).
    // The box height is reserved from the FIRST image's aspect ratio, so the
    // row never resizes as pages load or change; other pages crop into it.
    private func carousel(count: Int) -> some View {
        Color.clear
            .aspectRatio(Self.displayAspectRatio(images[0].aspectRatio), contentMode: .fit)
            .frame(maxHeight: 480)
            .overlay {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, img in
                            Color.clear
                                .containerRelativeFrame(.horizontal)
                                .overlay {
                                    AsyncCachedImage(url: img.thumbnailImageURL, maxPixelSize: 1400) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Color.secondary.opacity(0.2)
                                        }
                                    }
                                }
                                .clipped()
                                .contentShape(Rectangle())
                                // A plain tap only fires when the scroll pan
                                // doesn't claim the touch, so enlarging never
                                // gets in the way of swiping between pages.
                                .onTapGesture { handleTap(index) }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $carouselPage)
            }
            // Page dots, floating over the bottom of the media.
            .overlay(alignment: .bottom) {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { index in
                        Circle()
                            .fill(.white.opacity(index == (carouselPage ?? 0) ? 1 : 0.45))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.28), in: Capsule())
                .padding(.bottom, 8)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: carouselPage)
                .allowsHitTesting(false)
            }
    }

    /// Delegate to the owner's viewer when one is wired (ThreadView), else
    /// the window-level glass viewer, else our own fallback sheet.
    private func handleTap(_ index: Int) {
        if let onImageTap {
            onImageTap(images, index)
        } else if let viewerPresenter {
            viewerPresenter.present(images, at: index, postURI: postURI)
        } else {
            viewerIndex = index
            showViewer = true
        }
    }

    /// Width/height display ratio for reserving media space pre-load.
    /// Falls back to 3:2 when the record carries no ratio; clamps so
    /// portrait media caps near 6:7 (crops) and panoramas near 3:1.
    static func displayAspectRatio(
        _ ratio: AppBskyLexicon.Embed.AspectRatioDefinition?
    ) -> CGFloat {
        guard let ratio, ratio.height > 0, ratio.width > 0 else { return 1.5 }
        let raw = CGFloat(ratio.width) / CGFloat(ratio.height)
        return min(max(raw, 0.85), 3.0)
    }

    /// Small magnifying glass badge shown on single images to hint they're tappable.
    private var expandBadge: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(6)
            .background {
                Circle()
                    .fill(.ultraThinMaterial.opacity(0.85))
            }
            .padding(8)
    }
}

// MARK: - External Link Card
// Internal (not private): ThreadReaderView renders link previews inline.
//
// Bluesky-style layout on the app's glass surface: a full-width thumbnail
// (1.91:1, the Open Graph card ratio) over title, description, and a
// divided footer carrying the site icon + domain. Cards without a
// thumbnail collapse to the text block alone, like the official client.
//
// Links to a GIF (Tenor/KLIPY picks, any direct .gif) skip the card and
// play inline on a loop — see GIFEmbedView, which falls back to the card
// when the bytes turn out not to be a GIF.
struct ExternalLinkCardView: View {
    let external: AppBskyLexicon.Embed.ExternalDefinition.ViewExternal
    /// The owning post's media is labeled explicit — shields the GIF.
    var sensitiveMedia: Bool = false

    @Environment(\.openURL) private var openURL

    private var linkURL: URL? { URL(string: external.uri) }

    /// Footer domain, "www."-stripped the way Bluesky displays it.
    private var displayHost: String {
        guard let host = linkURL?.host else { return external.uri }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        if let gif = GIFLink.parse(external.uri) {
            GIFEmbedView(
                link: gif,
                thumbnailURL: external.thumbnailImageURL,
                altText: external.title,
                sensitiveMedia: sensitiveMedia
            ) {
                linkCard
            }
        } else {
            linkCard
        }
    }

    private var linkCard: some View {
        Button {
            if let url = linkURL { openURL(url) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let thumbURL = external.thumbnailImageURL {
                    // Height reserved from the fixed card ratio before the
                    // image loads — same no-reflow rule as feed media.
                    Color.clear
                        .aspectRatio(1.91, contentMode: .fit)
                        .overlay {
                            AsyncCachedImage(url: thumbURL) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.15)
                                }
                            }
                        }
                        .clipped()
                }

                VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                    if !external.title.isEmpty {
                        Text(external.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                    }
                    if !external.description.isEmpty {
                        Text(external.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    Divider()
                        .overlay(AtmoColors.glassDivider)
                        .padding(.vertical, 2)

                    HStack(spacing: 5) {
                        sourceIcon
                        Text(displayHost)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(AtmoTheme.Spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphicGlassCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(external.title.isEmpty
            ? "Link to \(displayHost)"
            : "\(external.title), link to \(displayHost)")
    }

    /// The site's favicon when the record carries one, else a globe.
    @ViewBuilder
    private var sourceIcon: some View {
        if let icon = external.source?.icon {
            AsyncCachedImage(url: icon) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Quote Post
// Bluesky-style embedded post on the app's glass surface: author header
// with timestamp, the text, and the quoted post's own media (images, a
// video still, or a compact link row) rendered inside the card.
// Internal (not private): the DM bubble renders shared posts with it.
struct QuotePostView: View {
    let record: AppBskyLexicon.Embed.RecordDefinition.ViewRecord

    /// The quoted post's media, labeled explicit by the author or a labeler.
    private var quoteSensitiveMedia: Bool {
        record.labels?.contains {
            PostItem.sensitiveMediaLabelValues.contains($0.name)
        } ?? false
    }

    var body: some View {
        NavigationLink(value: PostNavTarget(uri: record.uri)) {
            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    AvatarView(url: record.author.avatarImageURL, size: 20)
                    if let name = record.author.displayName, !name.isEmpty {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text("@\(record.author.actorHandle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(record.indexedAt.atmoFormatted())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let postRecord = record.value.getRecord(ofType: AppBskyLexicon.Feed.PostRecord.self),
                   !postRecord.text.isEmpty {
                    Text(postRecord.text)
                        .font(.callout)
                        .lineLimit(6)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                }

                // The quoted post's own media. Hit testing is off so every
                // tap on the card — media included — opens the quoted post,
                // exactly like the official client.
                if let media = record.embeds?.first {
                    QuotedMediaView(embed: media, sensitiveMedia: quoteSensitiveMedia)
                        .allowsHitTesting(false)
                }
            }
            .padding(AtmoTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphicGlassCard()
        }
        .buttonStyle(.plain)
        // NOTE: no .navigationDestination here — the owning stack registers
        // the PostNavTarget route once. Re-declaring it from every quote
        // card is an unsupported duplicate (and a per-row cost).
    }
}

// MARK: - Quoted Media
// Media inside a quote card. Videos render as a still with a play badge —
// the inline auto-player belongs to top-level embeds only, so a busy feed
// never runs two streams in one cell. External links use a compact row
// rather than the full card to keep the quote visually subordinate.
private struct QuotedMediaView: View {
    let embed: AppBskyLexicon.Embed.RecordDefinition.ViewRecord.EmbedsUnion
    var sensitiveMedia: Bool = false

    var body: some View {
        switch embed {
        case .embedImagesView(let images):
            ImageGridView(images: images.images, sensitiveMedia: sensitiveMedia)

        case .embedVideoView(let video):
            StaticVideoThumbnail(video: video)
                .sensitiveMediaShield(sensitiveMedia, key: video.playlistURI)
                .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))

        case .embedExternalView(let external):
            CompactExternalLinkRow(external: external.external, sensitiveMedia: sensitiveMedia)

        case .embedRecordWithMediaView(let rwm):
            switch rwm.media {
            case .embedImagesView(let images):
                ImageGridView(images: images.images, sensitiveMedia: sensitiveMedia)
            case .embedVideoView(let video):
                StaticVideoThumbnail(video: video)
                    .sensitiveMediaShield(sensitiveMedia, key: video.playlistURI)
                    .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
            default:
                EmptyView()
            }

        default:
            EmptyView()
        }
    }
}

// MARK: - Compact External Link Row
// The pre-redesign small link treatment, kept for quote cards where the
// full Bluesky-style card would out-weigh the quote itself.
private struct CompactExternalLinkRow: View {
    let external: AppBskyLexicon.Embed.ExternalDefinition.ViewExternal
    var sensitiveMedia: Bool = false

    private var host: String {
        guard let host = URL(string: external.uri)?.host else { return external.uri }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        // A quoted GIF still plays (quotes already show images and video
        // stills at full width); everything else keeps the compact row.
        if let gif = GIFLink.parse(external.uri) {
            GIFEmbedView(
                link: gif,
                thumbnailURL: external.thumbnailImageURL,
                altText: external.title,
                sensitiveMedia: sensitiveMedia
            ) {
                row
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            if let thumbURL = external.thumbnailImageURL {
                AsyncCachedImage(url: thumbURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 48, height: 48)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                if !external.title.isEmpty {
                    Text(external.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
                Text(host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(AtmoTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

// MARK: - Video Embed
// Streams the post's HLS video inline: muted by default, auto-playing
// once the user rests the scroll for about a second, looping, with a
// glass sound toggle (see EmbeddedVideoPlayer). Sensitive media keeps the
// static thumbnail + shield — nothing should auto-play behind a blur.
private struct VideoEmbedView: View {
    let video: AppBskyLexicon.Embed.VideoDefinition.View
    var sensitiveMedia: Bool = false

    /// Under a whole-post veil the video needs no shield of its own; the
    /// post's Show is the one reveal, after which it plays like any other.
    @Environment(\.coveredByPostShield) private var coveredByPost
    /// Measured row width; the box height is derived from it below.
    @State private var width: CGFloat = 0

    var body: some View {
        let shielded = sensitiveMedia && !coveredByPost
        let ratio = ImageGridView.displayAspectRatio(video.aspectRatio)
        // The box is sized explicitly from the measured width (capped at
        // 480 pt tall) rather than with aspectRatio + frame(maxHeight:) —
        // inside a scroll view that pair laid the player out at its full
        // height and clipped it, which put the expand, mute, and scrubber
        // controls of tall videos outside the visible crop.
        let height = width > 0 ? min(480, width / ratio) : 480 / max(ratio, 0.85)
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if !shielded, let playlistURL = URL(string: video.playlistURI) {
                    EmbeddedVideoPlayer(
                        playlistURL: playlistURL,
                        thumbnailURL: video.thumbnailImageURL.flatMap(URL.init(string:)),
                        videoPixelSize: video.aspectRatio.map { CGSize(width: $0.width, height: $0.height) }
                    )
                } else {
                    StaticVideoThumbnail(video: video)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .clipped()
            .sensitiveMediaShield(shielded, key: video.playlistURI)
            .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
            .accessibilityLabel(video.altText?.isEmpty == false ? "Video: \(video.altText!)" : "Video")
    }
}

// MARK: - Static Video Thumbnail
// Poster frame + play badge, used where the inline player doesn't run:
// sensitive media (shielded) and videos inside quote cards.
struct StaticVideoThumbnail: View {
    let video: AppBskyLexicon.Embed.VideoDefinition.View

    var body: some View {
        Color.clear
            .aspectRatio(ImageGridView.displayAspectRatio(video.aspectRatio), contentMode: .fit)
            .overlay {
                if let thumbString = video.thumbnailImageURL,
                   let thumbURL = URL(string: thumbString) {
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
            .overlay {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                    .atmoShadow(AtmoTheme.Shadow.floating)
            }
            .clipped()
    }
}
