import SwiftUI
import AtmoCore
import ATProtoKit

// MARK: - Thread Reader
/// Single-document view of an author's self-thread: the root post plus their
/// consecutive self-replies rendered as one continuous article — SF Pro body
/// text, with each post's images and link previews flowing inline.
struct ThreadReaderView: View {
    /// The author chain, oldest first (from `SelfThread.chain`).
    let posts: [PostItem]
    @Environment(\.dismiss) private var dismiss

    // Tap-to-enlarge for inline images: the Reader is itself a sheet, so
    // it hosts its OWN glass viewer (the root host sits behind the sheet).
    @State private var viewerPresenter = ImageViewerPresenter()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xl) {
                    if let first = posts.first {
                        header(for: first)
                        Divider()
                    }

                    ForEach(posts) { post in
                        paragraph(for: post)
                    }
                }
                .padding(.horizontal, AtmoTheme.Spacing.xl)
                .padding(.top, AtmoTheme.Spacing.lg)
                .padding(.bottom, AtmoTheme.Spacing.xxl)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Reader")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .themedBackdrop()
        }
        // Sheets can't lean on the root's browser host (a covered node
        // cannot present) — the Reader hosts its own for its link cards,
        // and its own glass image viewer for the same reason.
        .hostsInAppBrowser()
        .hostsImageViewer(viewerPresenter)
#if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
#endif
    }

    // MARK: Byline

    private func header(for first: PostItem) -> some View {
        HStack(spacing: AtmoTheme.Spacing.md) {
            AvatarView(url: first.authorAvatarURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(first.authorDisplayName ?? first.authorHandle)
                        .font(.headline)
                    if let badge = first.authorVerification {
                        VerifiedBadge(badge: badge)
                    }
                }
                Text("@\(first.authorHandle) · \(posts.count) posts · \(first.indexedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Paragraphs

    /// One post of the chain: its text as an article paragraph, then its
    /// media (images stacked full-width, article style) and link preview.
    @ViewBuilder
    private func paragraph(for post: PostItem) -> some View {
        let images = inlineImages(for: post)
        let external = externalLink(for: post)

        VStack(alignment: .leading, spacing: AtmoTheme.Spacing.md) {
            if !post.displayText.isEmpty {
                Text(post.displayText)
                    .font(.system(size: 17))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(Array(images.enumerated()), id: \.element.fullSizeImageURL) { index, image in
                inlineImage(image) {
                    viewerPresenter.present(images, at: index)
                }
                // Keyed like the feed's image grid (first image), so a reveal in
                // either place covers the post's image set in both.
                .sensitiveMediaShield(post.hasSensitiveMediaLabel, key: images.first?.thumbnailImageURL.absoluteString ?? post.uri)
            }

            if let external {
                ExternalLinkCardView(external: external)
            }
        }
    }

    /// Full-width article figure with the row height reserved from the
    /// record's aspect ratio (no reflow when the download lands).
    private func inlineImage(
        _ image: AppBskyLexicon.Embed.ImagesDefinition.ViewImage,
        onTap: @escaping () -> Void
    ) -> some View {
        Color.clear
            .aspectRatio(ImageGridView.displayAspectRatio(image.aspectRatio), contentMode: .fit)
            .overlay {
                AsyncCachedImage(url: image.fullSizeImageURL) { phase in
                    if let loaded = phase.image {
                        loaded.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
            }
            .frame(maxHeight: 520)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
            .onTapGesture(perform: onTap)
    }

    // MARK: Embed extraction

    private func inlineImages(for post: PostItem) -> [AppBskyLexicon.Embed.ImagesDefinition.ViewImage] {
        switch post.embed {
        case .embedImagesView(let view):
            return view.images
        case .embedRecordWithMediaView(let recordWithMedia):
            if case .embedImagesView(let view) = recordWithMedia.media { return view.images }
            return []
        default:
            return []
        }
    }

    private func externalLink(for post: PostItem) -> AppBskyLexicon.Embed.ExternalDefinition.ViewExternal? {
        switch post.embed {
        case .embedExternalView(let view):
            return view.external
        case .embedRecordWithMediaView(let recordWithMedia):
            if case .embedExternalView(let view) = recordWithMedia.media { return view.external }
            return nil
        default:
            return nil
        }
    }
}
