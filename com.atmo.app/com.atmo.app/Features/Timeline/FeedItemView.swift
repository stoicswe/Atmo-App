import SwiftUI
import ATProtoKit

// MARK: - FeedItemView
// Displays a single post in the timeline.
// If the post is a reply, shows up to 2 parent posts above it with connector
// lines. When the thread is longer than 2 the top connector shows a "more"
// indicator pill so the user knows they can tap to see the full thread.
struct FeedItemView: View {
    let post: PostItem
    let viewModel: TimelineViewModel
    var onTap: (() -> Void)? = nil
    /// Called when the user taps a @mention in the post text.
    /// Receives a handle (without "@") from regex fallback, or a DID from server facets.
    /// ProfileView accepts either form via its actorDID parameter.
    var onMentionTap: ((String) -> Void)? = nil

    // Hashtag taps are handled via the environment action injected by AppNavigation,
    // so no explicit callback prop is needed here.
    @Environment(\.hashtagSearch) private var hashtagSearch

    // Cache translation check so NLLanguageRecognizer doesn't run on every render
    @State private var needsTranslation: Bool = false

    // The post passed in is always the live copy from the viewModel's ForEach —
    // no need for an O(n) lookup. Optimistic updates flow through the ViewModel
    // which invalidates the ForEach, passing the updated PostItem down automatically.
    private var livePost: PostItem { post }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Repost reason header ──
            if case .repost(_, let byHandle, let byDisplayName, _) = livePost.reason {
                Label(
                    "\(byDisplayName ?? "@\(byHandle)") reposted",
                    systemImage: "arrow.2.squarepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading,
                    AtmoTheme.Feed.avatarSize +
                    AtmoTheme.Feed.avatarTextSpacing +
                    AtmoTheme.Feed.horizontalPadding)
                .padding(.top, AtmoTheme.Spacing.sm)
                .padding(.bottom, AtmoTheme.Spacing.xs)
            }

            // ── Thread context (parent posts shown above a reply) ──
            if livePost.replyParentURI != nil {
                ThreadContextView(
                    post: livePost,
                    onTap: onTap
                )
            }

            // ── The post itself ──
            HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
                // Avatar — taps to profile
                NavigationLink(value: livePost.authorDID) {
                    AvatarView(url: livePost.authorAvatarURL, size: AtmoTheme.Feed.avatarSize)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                    // Author + timestamp line — tapping anywhere here opens the thread.
                    // This row gets its own targeted tap gesture so the outer VStack no
                    // longer needs a blanket .onTapGesture that would swallow link taps.
                    HStack(alignment: .center, spacing: AtmoTheme.Spacing.xs) {
                        if let name = livePost.authorDisplayName {
                            Text(name)
                                .font(AtmoFonts.authorName)
                                .lineLimit(1)
                        }
                        Text("@\(livePost.authorHandle)")
                            .font(AtmoFonts.authorHandle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(livePost.indexedAt.atmoFormatted())
                            .font(AtmoFonts.timestamp)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?() }

                    // Post text — @mention / #hashtag / URL taps are handled by RichTextView's
                    // internal Text link handler (via AttributedString .link attributes).
                    // Plain-text taps pass through to the outer VStack's .onTapGesture,
                    // which opens the thread. displayText strips the trailing embed URL.
                    if !livePost.displayText.isEmpty {
                        RichTextView(
                            text: livePost.displayText,
                            facets: livePost.facets,
                            onMentionTap: { handle in onMentionTap?(handle) },
                            onHashtagTap: { tag in hashtagSearch(tag) }
                        )
                        // No tap gesture needed here — the outer VStack's .onTapGesture
                        // fires for plain-text regions (Text passes through non-link taps).
                        // Link runs (URLs, mentions, hashtags) intercept their own taps
                        // via the .link attribute, suppressing the parent gesture naturally.

                        // Translate button — only when post appears to be in a foreign language
                        // (result cached in @State to avoid running NLLanguageRecognizer every render)
                        if needsTranslation {
                            TranslateButton(text: livePost.displayText)
                                .padding(.top, 2)
                        }
                    }

                    // Embed — tapping opens the thread
                    if let embed = livePost.embed {
                        PostEmbedView(embed: embed)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap?() }
                            .padding(.top, AtmoTheme.Spacing.xs)
                    }

                    // Action row — each button handles its own tap; no outer gesture needed
                    PostActionsView(post: livePost, viewModel: viewModel, showBookmark: true)
                        .padding(.top, AtmoTheme.Spacing.sm)
                }
            }
            .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
            .padding(.vertical, AtmoTheme.Feed.verticalPadding)
        }
        // Make dead-zone areas (horizontal padding, avatar column below the avatar) respond
        // to taps. .onTapGesture on the outer VStack fires only when no interactive child
        // (NavigationLink, Button, or view with its own gesture) has already consumed
        // the tap — so the avatar → profile link, rich-text links, and action buttons
        // all continue to work unaffected.
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .task(id: livePost.id) {
            // Detect language at utility priority; runs on the cooperative thread pool
            // but stays within the view's @MainActor isolation so @State writes are safe.
            // Use displayText so the stripped URL doesn't skew the language detector.
            let text = livePost.displayText
            needsTranslation = await Task(priority: .utility) {
                TranslationHelper.needsTranslation(text)
            }.value
        }
    }
}

// MARK: - Thread Context View
// Shows parent posts above a reply in the timeline.
// Fetches up to 2 parent posts via getPostThread; if the thread root is further
// away, shows a "more in thread" indicator at the top.
//
// IMPORTANT: This view uses a fixed minimum height to prevent layout jumps when
// the async parent fetch completes and the skeleton transitions to real content.
// The skeleton and loaded states are kept at approximately equal heights.
private struct ThreadContextView: View {
    let post: PostItem
    var onTap: (() -> Void)?

    @Environment(ATProtoService.self) private var service
    @State private var parents: [PostItem] = []   // ordered: oldest first
    @State private var hasMoreAbove: Bool = false
    @State private var loaded: Bool = false

    private let maxParentsShown = 2
    private let ctxAvatarSize: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !loaded {
                skeletonRow
            } else {
                if !parents.isEmpty {
                    // "More in thread" pill
                    if hasMoreAbove {
                        moreIndicatorRow
                    }

                    // Parent rows + vertical connector lines
                    ForEach(Array(parents.enumerated()), id: \.element.id) { _, parent in
                        ParentPostRow(
                            post: parent,
                            avatarSize: ctxAvatarSize,
                            onTap: onTap
                        )
                        threadConnectorLine(
                            centerX: AtmoTheme.Feed.horizontalPadding + ctxAvatarSize / 2
                        )
                    }
                }
                // If parents is empty after loading (fetch failed / no parents), show nothing
                // — height collapses to 0, which is correct (no parent to show)
            }
        }
        // Suppress implicit animations on the skeleton → content transition.
        // Without this, the height change as parents load fires a layout animation
        // that scrolls the feed content visibly during momentum scroll.
        .animation(.none, value: loaded)
        .task(id: post.id) {
            await fetchParents()
        }
    }

    // Small vertical line connecting parent avatar to the next row
    private func threadConnectorLine(centerX: CGFloat) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 2, height: 12)
            .padding(.leading, centerX - 1)
    }

    // Dotted "more in thread" row
    private var moreIndicatorRow: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 3, height: 3)
                }
            }
            .frame(width: ctxAvatarSize, alignment: .center)

            Text("More in thread")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    // Placeholder skeleton while fetching — matches approximate height of a single parent row
    private var skeletonRow: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            Circle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: ctxAvatarSize, height: ctxAvatarSize)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 100, height: 10)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 200, height: 10)
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.xs)
    }

    // Walk the thread parent chain using getPostThread.
    // Guard on `loaded` first — LazyVStack re-triggers .task on scroll recycling;
    // this ensures we never re-fetch or re-render once the data is in place.
    private func fetchParents() async {
        guard !loaded else { return }
        guard let kit = service.atProtoKit else { loaded = true; return }
        do {
            let output = try await kit.getPostThread(from: post.uri)
            guard case .threadViewPost(let thread) = output.thread else {
                loaded = true; return
            }

            // Walk parent chain (ATProto nests parents recursively)
            var chain: [PostItem] = []
            var current = thread.parent
            while let parentUnion = current {
                if case .threadViewPost(let parentThread) = parentUnion {
                    chain.append(PostItem(postView: parentThread.post))
                    current = parentThread.parent
                } else {
                    break
                }
            }

            // chain is newest-first; reverse so oldest is first in display
            chain.reverse()

            if chain.count > maxParentsShown {
                hasMoreAbove = true
                parents = Array(chain.suffix(maxParentsShown))
            } else {
                hasMoreAbove = false
                parents = chain
            }
        } catch {
            // Silently fail — thread context is a nice-to-have
        }
        loaded = true
    }
}

// MARK: - Parent Post Row
// A compact, read-only row showing a parent post in thread context.
private struct ParentPostRow: View {
    let post: PostItem
    let avatarSize: CGFloat
    var onTap: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            AvatarView(url: post.authorAvatarURL, size: avatarSize)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    if let name = post.authorDisplayName {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text("@\(post.authorHandle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(post.indexedAt.atmoFormatted())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}
