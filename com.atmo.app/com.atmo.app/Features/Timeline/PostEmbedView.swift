import SwiftUI
import ATProtoKit

/// Renders the embed attached to a post: images, external links, record quotes, etc.
///
/// - `onImageTap`: Optional callback invoked when the user taps an image in the grid.
///   Receives `(images, tappedIndex)` so the caller can present `ImageViewerView`.
///   When nil, images are not interactive (timeline behaviour).
struct PostEmbedView: View {
    let embed: AppBskyLexicon.Feed.PostViewDefinition.EmbedUnion
    /// Called with the full image array and the tapped index so the parent can
    /// present ImageViewerView. Pass nil to keep images non-interactive (timeline).
    var onImageTap: (([AppBskyLexicon.Embed.ImagesDefinition.ViewImage], Int) -> Void)? = nil

    var body: some View {
        Group {
            switch embed {
            case .embedImagesView(let images):
                ImageGridView(images: images.images, onImageTap: onImageTap)

            case .embedExternalView(let external):
                ExternalLinkCardView(external: external.external)

            case .embedRecordView(let record):
                if case .viewRecord(let viewRecord) = record.record {
                    QuotePostView(record: viewRecord)
                }

            case .embedRecordWithMediaView(let rwm):
                VStack(spacing: AtmoTheme.Spacing.sm) {
                    if case .embedImagesView(let images) = rwm.media {
                        ImageGridView(images: images.images, onImageTap: onImageTap)
                    }
                    if case .viewRecord(let viewRecord) = rwm.record.record {
                        QuotePostView(record: viewRecord)
                    }
                }

            case .embedVideoView(let video):
                VideoEmbedView(video: video)

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
private struct ImageGridView: View {
    let images: [AppBskyLexicon.Embed.ImagesDefinition.ViewImage]
    /// When non-nil, tapping an image calls this with (allImages, tappedIndex).
    var onImageTap: (([AppBskyLexicon.Embed.ImagesDefinition.ViewImage], Int) -> Void)? = nil

    var body: some View {
        let count = images.count
        Group {
            if count == 1 {
                AsyncCachedImage(url: images[0].fullSizeImageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.2)
                    }
                }
                .frame(maxHeight: 300)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    onImageTap?(images, 0)
                }
                // Show a subtle "tap to expand" affordance when interactive
                .overlay(alignment: .bottomTrailing) {
                    if onImageTap != nil {
                        expandBadge
                    }
                }
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: min(count, 2)),
                    spacing: 2
                ) {
                    ForEach(Array(images.prefix(4).enumerated()), id: \.element.fullSizeImageURL) { index, img in
                        AsyncCachedImage(url: img.thumbnailImageURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.2)
                            }
                        }
                        .frame(height: 150)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onImageTap?(images, index)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
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
private struct ExternalLinkCardView: View {
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
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)
                    .stroke(AtmoColors.glassBorder, lineWidth: 0.5)
            )
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
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)
                    .stroke(AtmoColors.glassBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .navigationDestination(for: PostNavTarget.self) { target in
            ThreadView(postURI: target.uri)
        }
    }
}

// MARK: - Video Embed Placeholder
private struct VideoEmbedView: View {
    let video: AppBskyLexicon.Embed.VideoDefinition.View

    var body: some View {
        ZStack {
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

            Image(systemName: "play.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)
                .atmoShadow(AtmoTheme.Shadow.floating)
        }
        .frame(maxHeight: 240)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
    }
}
