import SwiftUI
import AtmoCore
import ATProtoKit

// MARK: - FeedItemView
// Displays one timeline slice: when the post is a reply, its root and parent
// (delivered inline by the timeline API — no extra fetch) render above it as
// full posts connected by a thread rail, oldest first. So a conversation
// reads chronologically inside the slice while the slice itself sits at the
// feed position of its newest post — the way Bluesky/X render threads.
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

            // ── Thread context (root/parent shown above a reply) ──
            // Full posts from the feed payload, oldest first, joined by a
            // rail. Dotted breaks mark skipped generations.
            if !livePost.threadAncestors.isEmpty {
                ForEach(Array(livePost.threadAncestors.enumerated()), id: \.element.id) { index, ancestor in
                    if index == 1, livePost.threadContextHasGap {
                        ThreadGapRow(onTap: onTap)
                    }
                    AncestorPostRow(
                        post: ancestor,
                        isFirst: index == 0,
                        selfThreadPosition: livePost.selfThreadCount.map { (index + 1, $0) },
                        // Gapped self-thread: exact numbering is impossible
                        // from the feed payload, so the root carries an
                        // unnumbered "Thread" marker instead.
                        showsThreadHint: index == 0
                            && livePost.selfThreadCount == nil
                            && livePost.isSelfThreadSlice,
                        onTap: onTap,
                        onMentionTap: onMentionTap
                    )
                }
                if livePost.threadContextIsDetached {
                    ThreadGapRow(onTap: onTap)
                }
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
                        if let badge = livePost.authorVerification {
                            VerifiedBadge(badge: badge)
                        }
                        Text("@\(livePost.authorHandle)")
                            .font(AtmoFonts.authorHandle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let count = livePost.selfThreadCount {
                            SelfThreadPill(index: count, count: count, glass: true)
                        }
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
                        PostEmbedView(embed: embed, sensitiveMedia: livePost.hasSensitiveMediaLabel)
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
            // With thread context above, the ancestor's rail runs flush to
            // this row so the avatars read as one connected chain.
            .padding(.top, livePost.threadAncestors.isEmpty ? AtmoTheme.Feed.verticalPadding : 0)
            .padding(.bottom, AtmoTheme.Feed.verticalPadding)
        }
        // Make dead-zone areas (horizontal padding, avatar column below the avatar) respond
        // to taps. .onTapGesture on the outer VStack fires only when no interactive child
        // (NavigationLink, Button, or view with its own gesture) has already consumed
        // the tap — so the avatar → profile link, rich-text links, and action buttons
        // all continue to work unaffected.
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .task(id: livePost.id) {
            // Use displayText so the stripped URL doesn't skew the detector.
            let text = livePost.displayText
            let uri = livePost.uri
            // Cells recycle constantly while scrolling — reuse this post's
            // earlier result instead of re-running language detection.
            if let cached = TranslationCheckCache.value(for: uri) {
                needsTranslation = cached
                return
            }
            // Detached: a plain Task {} inherits this view's MainActor,
            // which was running NLLanguageRecognizer on the main thread.
            let result = await Task.detached(priority: .utility) {
                TranslationHelper.needsTranslation(text)
            }.value
            TranslationCheckCache.store(result, for: uri)
            needsTranslation = result
        }
    }
}

// MARK: - Translation Check Cache
/// Session cache of per-post language-detection results.
@MainActor
private enum TranslationCheckCache {
    private static var values: [String: Bool] = [:]

    static func value(for uri: String) -> Bool? { values[uri] }

    static func store(_ value: Bool, for uri: String) {
        if values.count > 2000 { values.removeAll(keepingCapacity: true) }
        values[uri] = value
    }
}

// MARK: - Ancestor Post Row
// A full-size post row for thread context above a reply — same visual weight
// as the main post (name line, rich text, embeds) minus the action bar, with
// a rail running from the avatar to the next row. Tapping opens the thread,
// where the full conversation and all actions live.
private struct AncestorPostRow: View {
    let post: PostItem
    /// First row of the feed cell — carries the cell's top breathing room.
    let isFirst: Bool
    /// This row's (position, total) within an author self-thread, when the
    /// cell shows one — drives the "k/n" pill.
    var selfThreadPosition: (index: Int, count: Int)? = nil
    /// Gapped self-thread root: show an unnumbered "Thread" marker where
    /// the connected chain would show "1/n".
    var showsThreadHint: Bool = false
    var onTap: (() -> Void)?
    var onMentionTap: ((String) -> Void)?

    @Environment(\.hashtagSearch) private var hashtagSearch

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            // Avatar column: avatar + continuation rail down to the next row.
            VStack(spacing: 3) {
                NavigationLink(value: post.authorDID) {
                    AvatarView(url: post.authorAvatarURL, size: AtmoTheme.Feed.avatarSize)
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: AtmoTheme.Feed.avatarSize)

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                HStack(alignment: .center, spacing: AtmoTheme.Spacing.xs) {
                    if let name = post.authorDisplayName {
                        Text(name)
                            .font(AtmoFonts.authorName)
                            .lineLimit(1)
                    }
                    if let badge = post.authorVerification {
                        VerifiedBadge(badge: badge)
                    }
                    Text("@\(post.authorHandle)")
                        .font(AtmoFonts.authorHandle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Later chain members wear their position by the
                    // timestamp; the root's pill sits at the end of its
                    // text (below) like the thread screen.
                    if let position = selfThreadPosition, !isFirst {
                        SelfThreadPill(index: position.index, count: position.count, glass: true)
                    }
                    Text(post.indexedAt.atmoFormatted())
                        .font(AtmoFonts.timestamp)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }

                if !post.displayText.isEmpty {
                    RichTextView(
                        text: post.displayText,
                        facets: post.facets,
                        onMentionTap: { handle in onMentionTap?(handle) },
                        onHashtagTap: { tag in hashtagSearch(tag) }
                    )
                }

                // Chain root: glass pill trailing the text — "1/n" when the
                // whole chain is visible, "Thread" when generations are
                // missing (tapping through shows exact numbers).
                if isFirst, selfThreadPosition != nil || showsThreadHint {
                    HStack {
                        Spacer(minLength: 0)
                        if let position = selfThreadPosition {
                            SelfThreadPill(index: position.index, count: position.count, glass: true)
                        } else {
                            ThreadHintPill()
                        }
                    }
                }

                if let embed = post.embed {
                    PostEmbedView(embed: embed, sensitiveMedia: post.hasSensitiveMediaLabel)
                        .contentShape(Rectangle())
                        .onTapGesture { onTap?() }
                        .padding(.top, AtmoTheme.Spacing.xs)
                }
            }
            // Breathing room before the next row lives INSIDE the content
            // column, so the rail beside it runs unbroken to the row's edge.
            .padding(.bottom, AtmoTheme.Spacing.md)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.top, isFirst ? AtmoTheme.Feed.verticalPadding : 0)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

// MARK: - Thread Gap Row
// Dotted "More in thread" break shown where the visible context skips
// generations (parent isn't a direct reply to the root, or the direct
// parent is deleted/blocked). Tapping opens the full thread.
private struct ThreadGapRow: View {
    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 3, height: 3)
                }
            }
            .frame(width: AtmoTheme.Feed.avatarSize, alignment: .center)

            Text("More in thread")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

// MARK: - Self-Thread Pill
/// Small "k/n" capsule marking a post's place in its author's own thread
/// (the root plus their consecutive self-replies shown in the cell).
struct SelfThreadPill: View {
    let index: Int
    let count: Int
    /// Liquid Glass backing (thread screen) instead of the accent tint fill
    /// used in feed cells.
    var glass: Bool = false

    var body: some View {
        let label = Text("\(index)/\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(AtmoColors.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, glass ? 3 : 2)
        Group {
            if glass {
                label.glassEffect(.regular, in: Capsule())
            } else {
                label.background(AtmoColors.accent.opacity(0.14), in: Capsule())
            }
        }
        .accessibilityLabel("Post \(index) of \(count) in thread")
    }
}

/// Unnumbered variant of the self-thread marker, for feed cells where the
/// chain has missing generations and exact numbering would be a guess.
struct ThreadHintPill: View {
    var body: some View {
        Text("Thread")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AtmoColors.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: Capsule())
            .accessibilityLabel("Part of a thread by this author")
    }
}
