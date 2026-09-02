import SwiftUI
import AtmoCore

struct PostActionsView: View {
    // `post` is the identity anchor (uri/cid for API calls); mutable state
    // (isLiked, likeCount, etc.) is read from `livePost` so optimistic updates
    // from the ViewModel are reflected immediately without waiting for a full
    // ForEach re-render of the parent cell.
    let post: PostItem
    let viewModel: TimelineViewModel
    /// When true, a bookmark ribbon button is shown after the share button.
    /// Only pass true for top-level timeline posts and the root post of a thread —
    /// not for reply rows.
    var showBookmark: Bool = false

    @Environment(ATProtoService.self) private var service
    @State private var showRepostMenu: Bool = false
    @State private var showReplyComposer: Bool = false
    @State private var showQuoteComposer: Bool = false
    /// "Send post in a message" — the in-app DM recipient picker.
    @State private var showSendSheet: Bool = false
    /// Tracks whether a quote post was successfully submitted this session so
    /// the repost button can turn green immediately without waiting for a timeline refresh.
    @State private var didQuotePost: Bool = false

    /// Always reads the freshest copy of this post from the ViewModel.
    /// Falls back to the original `post` if it's no longer in the list
    /// (e.g. while a refresh replaces the array).
    private var livePost: PostItem {
        // livePost(uri:) also finds posts the timeline holds only as thread
        // context above another post (the action row on ancestor rows).
        viewModel.livePost(uri: post.uri) ?? post
    }

    /// Ghost posts: thread closed, counts hidden, Reply becomes a private
    /// message to the author — offered only when messaging is possible.
    private var isGhost: Bool { GhostPostPolicy.isGhost(livePost) }

    /// The viewer can DM at all: chat available, their own DMs not turned
    /// off, not their own post, and family controls allowing a new chat.
    private var canReplyPrivately: Bool {
        guard isGhost, service.atProtoChat != nil,
              livePost.authorDID != service.currentUserDID
        else { return false }
        if let did = service.currentUserDID,
           AccountProfileCache.shared.snapshot(for: did)?.dmsEnabled == false {
            return false
        }
        return ParentalControlsStore.shared.canStartDM(with: livePost.authorHandle)
    }

    private func replyPrivately() {
        Haptics.tap()
        Task {
            let vm = NewConversationViewModel(service: service)
            if let convo = await vm.openConversation(with: livePost.authorDID) {
                AppRouter.shared.pendingConversation = convo
            }
        }
    }

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.xl) {
            if isGhost {
                if canReplyPrivately {
                    ActionButton(icon: "envelope", count: 0, color: .secondary) {
                        replyPrivately()
                    }
                    .accessibilityLabel("Reply privately")
                }
            } else {
            // Reply
            ActionButton(
                icon: "bubble.left",
                count: livePost.replyCount,
                color: .secondary
            ) {
                Haptics.tap()
                showReplyComposer = true
            }
            }

            // Ghost posts: Bluesky can't block reposts, so Atmo simply
            // doesn't offer the button (or show the count) on them.
            if !isGhost {
            // Repost — green when the user has reposted OR quoted this post.
            // Uses a popover on macOS (confirmationDialog is unreliable
            // in NavigationSplitView detail columns on macOS) and confirmationDialog on iOS.
            let isRepostActive = livePost.isReposted || livePost.isQuoted || didQuotePost
            ActionButton(
                icon: "arrow.2.squarepath",
                count: isGhost ? 0 : livePost.repostCount,
                color: isRepostActive ? AtmoColors.repostGreen : .secondary,
                filled: isRepostActive
            ) {
                Haptics.tap()
                showRepostMenu = true
            }
#if os(macOS)
            .popover(isPresented: $showRepostMenu, arrowEdge: .bottom) {
                RepostMenuView(
                    isReposted: livePost.isReposted,
                    onRepost: {
                        showRepostMenu = false
                        let captured = livePost
                        // Rigid confirm for committing a repost; softer on undo.
                        if captured.isReposted { Haptics.soft() } else { Haptics.confirm() }
                        Task { await viewModel.toggleRepost(post: captured) }
                    },
                    onQuote: {
                        showRepostMenu = false
                        Haptics.tap()
                        showQuoteComposer = true
                    },
                    onCancel: { showRepostMenu = false }
                )
            }
#else
            .confirmationDialog("Repost", isPresented: $showRepostMenu) {
                Button(livePost.isReposted ? "Undo Repost" : "Repost") {
                    let captured = livePost
                    // Rigid confirm for committing a repost; softer on undo.
                    if captured.isReposted { Haptics.soft() } else { Haptics.confirm() }
                    Task { await viewModel.toggleRepost(post: captured) }
                }
                Button("Quote Post") {
                    Haptics.tap()
                    showQuoteComposer = true
                }
                Button("Cancel", role: .cancel) {}
            }
#endif
            }

            // Like
            ActionButton(
                icon: livePost.isLiked ? "heart.fill" : "heart",
                count: isGhost ? 0 : livePost.likeCount,
                color: livePost.isLiked ? AtmoColors.likeRed : .secondary,
                filled: livePost.isLiked
            ) {
                let captured = livePost
                // Liking gets the heartbeat; unliking just a soft release.
                if captured.isLiked { Haptics.soft() } else { Haptics.heartbeat() }
                Task { await viewModel.toggleLike(post: captured) }
            }

            // Send — share the post into a conversation inside the app
            // (it arrives as a tappable post card, like the official client).
            ActionButton(icon: "paperplane", count: 0, color: .secondary) {
                Haptics.tap()
                showSendSheet = true
            }
            .accessibilityLabel("Send post in a message")

            Spacer()

            // Share — opens the native share sheet on iOS and macOS.
            // ShareLink works without any platform guards; the system provides
            // the appropriate sheet (UIActivityViewController / NSSharingServicePicker).
            // Providing both the URL and a `message` gives iMessage a rich preview:
            // the URL becomes a link card and the text appears as the message body.
            if let url = livePost.bskyWebURL {
                ShareLink(
                    item: url,
                    subject: Text(livePost.authorDisplayName ?? "@\(livePost.authorHandle)"),
                    message: Text(livePost.text.isEmpty ? url.absoluteString : livePost.text)
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                // ShareLink owns its tap; ride alongside it for the haptic.
                .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
            }

            // Bookmark — only shown on top-level timeline posts and thread root posts.
            if showBookmark {
                let isBookmarked = BookmarkStore.shared.isBookmarked(livePost)
                Button {
                    Haptics.soft()
                    BookmarkStore.shared.toggle(livePost)
                } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.callout)
                        .foregroundStyle(isBookmarked ? AtmoColors.accent : .secondary)
                        .symbolEffect(.bounce, value: isBookmarked)
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isBookmarked)
            }
        }
        .sheet(isPresented: $showReplyComposer) {
            ComposerView(replyTo: livePost)
        }
        .sheet(isPresented: $showSendSheet) {
            SendPostSheet(post: livePost)
        }
        .sheet(isPresented: $showQuoteComposer) {
            // Capture post identity at sheet-open time so the callback uses
            // the correct post even if livePost changes while the sheet is open.
            let capturedPost = livePost
            ComposerView(quotedPost: capturedPost, onSuccess: {
                viewModel.markAsQuoted(post: capturedPost)
                didQuotePost = true
            })
        }
    }
}

// MARK: - macOS Repost Menu
// A compact popover-based menu that replaces confirmationDialog on macOS,
// where confirmationDialog attaches to the window rather than the triggering view
// and can be non-interactive inside NavigationSplitView detail columns.
#if os(macOS)
private struct RepostMenuView: View {
    let isReposted: Bool
    let onRepost: () -> Void
    let onQuote: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: onRepost) {
                Label(
                    isReposted ? "Undo Repost" : "Repost",
                    systemImage: isReposted ? "arrow.2.squarepath" : "arrow.2.squarepath"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isReposted ? AtmoColors.repostGreen : .primary)
            .padding(.horizontal, AtmoTheme.Spacing.md)
            .padding(.vertical, AtmoTheme.Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous)
                    .fill(Color.primary.opacity(0.001)) // hit-test area
            }
            .contentShape(Rectangle())

            Divider()

            Button(action: onQuote) {
                Label("Quote Post", systemImage: "quote.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .padding(.horizontal, AtmoTheme.Spacing.md)
            .padding(.vertical, AtmoTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .padding(AtmoTheme.Spacing.xs)
        .frame(minWidth: 160)
    }
}
#endif

// MARK: - Action Button
private struct ActionButton: View {
    let icon: String
    let count: Int
    var color: Color = .secondary
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.callout)
                    .symbolEffect(.bounce, value: filled)
                if count > 0 {
                    Text(count.formatted(.number.notation(.compactName)))
                        .font(AtmoFonts.actionCount)
                }
            }
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: filled)
    }
}
