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

    var body: some View {
        Group {
            switch embed {
            case .embedImagesView(let images):
                ImageGridView(images: images.images, onImageTap: onImageTap, sensitiveMedia: sensitiveMedia)

            case .embedExternalView(let external):
                ExternalLinkCardView(external: external.external)

            case .embedRecordView(let record):
                if case .viewRecord(let viewRecord) = record.record {
                    QuotePostView(record: viewRecord)
                }

            case .embedRecordWithMediaView(let rwm):
                VStack(spacing: AtmoTheme.Spacing.sm) {
                    if case .embedImagesView(let images) = rwm.media {
                        ImageGridView(images: images.images, onImageTap: onImageTap, sensitiveMedia: sensitiveMedia)
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

    /// Flagged by on-device analysis (Apple's Sensitive Content Warning)
    /// when the post carried no label.
    @State private var screenerFlagged = false

    /// Carousel page currently snapped into view (drives the dots).
    @State private var carouselPage: Int? = 0
    /// Fallback viewer state, used when no onImageTap delegate is provided.
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
                        AsyncCachedImage(url: images[0].fullSizeImageURL) { phase in
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
        .sensitiveMediaShield(sensitiveMedia || screenerFlagged)
        .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
        .sheet(isPresented: $showViewer) {
            ImageViewerView(images: images, selectedIndex: $viewerIndex)
        }
        // Unlabeled images get the same on-device screening iMessage uses,
        // when the person has Sensitive Content Warning enabled.
        .task(id: images.first?.thumbnailImageURL) {
            guard !sensitiveMedia,
                  SensitiveMediaPolicy.stored(
                    rawValue: UserDefaults.standard.string(forKey: SensitiveMediaPolicy.storageKey)
                  ) != .show,
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
                                    AsyncCachedImage(url: img.thumbnailImageURL) { phase in
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
    /// present our own.
    private func handleTap(_ index: Int) {
        if let onImageTap {
            onImageTap(images, index)
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
struct ExternalLinkCardView: View {
    let external: AppBskyLexicon.Embed.ExternalDefinition.ViewExternal

    @Environment(\.openURL) private var openURL

    private var linkURL: URL? { URL(string: external.uri) }

    var body: some View {
        Button {
            if let url = linkURL { openURL(url) }
        } label: {
            HStack(spacing: AtmoTheme.Spacing.md) {
                if let thumbURL = external.thumbnailImageURL {
                    AsyncCachedImage(url: thumbURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 2) {
                    if !external.title.isEmpty {
                        Text(external.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                    Text(linkURL?.host ?? external.uri)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(AtmoTheme.Spacing.md)
            .neumorphicGlassCard()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quote Post
private struct QuotePostView: View {
    let record: AppBskyLexicon.Embed.RecordDefinition.ViewRecord

    var body: some View {
        NavigationLink(value: PostNavTarget(uri: record.uri)) {
            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {
                HStack(spacing: AtmoTheme.Spacing.sm) {
                    AvatarView(url: record.author.avatarImageURL, size: 20)
                    if let name = record.author.displayName {
                        Text(name).font(.caption.weight(.semibold))
                    }
                    Text("@\(record.author.actorHandle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let postRecord = record.value.getRecord(ofType: AppBskyLexicon.Feed.PostRecord.self) {
                    Text(postRecord.text)
                        .font(.callout)
                        .lineLimit(4)
                        .foregroundStyle(.primary)
                }
            }
            .padding(AtmoTheme.Spacing.md)
            .neumorphicGlassCard()
        }
        .buttonStyle(.plain)
        // NOTE: no .navigationDestination here — the owning stack registers
        // the PostNavTarget route once. Re-declaring it from every quote
        // card is an unsupported duplicate (and a per-row cost).
    }
}

// MARK: - Video Embed Placeholder
private struct VideoEmbedView: View {
    let video: AppBskyLexicon.Embed.VideoDefinition.View
    var sensitiveMedia: Bool = false

    var body: some View {
        // Same pre-reserved sizing as images: the box height comes from the
        // record's aspect ratio, not from whether the thumbnail has loaded.
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
            .frame(maxHeight: 480)
            .clipped()
            .sensitiveMediaShield(sensitiveMedia)
            .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
    }
}
