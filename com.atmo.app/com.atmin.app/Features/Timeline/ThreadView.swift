import SwiftUI
import ATProtoKit

// MARK: - Layout Constants
private let avatarSize: CGFloat = 38
private let replyAvatarSize: CGFloat = 32
private let lineWidth: CGFloat = 2
private let indentStep: CGFloat = replyAvatarSize / 2 + 10
/// Height of the CurvedConnector frame.
/// Must equal replyAvatarSize so that rect.midY (= 16 pt) lands exactly on
/// the child avatar's vertical centre inside the content VStack.
private let connectorHeight: CGFloat = replyAvatarSize

// MARK: - Reply Sort Order
enum ReplySortOrder: String, CaseIterable, Identifiable {
    case time = "Time"
    case hot  = "Hot"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .time: return "clock"
        case .hot:  return "flame"
        }
    }
}

// MARK: - Thread Reply Model
struct ThreadReply: Identifiable {
    var id: String { post.id }
    let post: PostItem
    let depth: Int
    /// True when this node has at least one child in the full (unfiltered) tree
    var hasChildren: Bool = false
    /// The URI of this node's direct parent reply (nil if depth 0 / direct reply to root)
    var parentID: String? = nil
    /// True for replies optimistically inserted before the server round-trip completes.
    var isPending: Bool = false
}

// MARK: - ThreadView
struct ThreadView: View {
    let postURI: String
    @Environment(ATProtoService.self) private var service

    @State private var rootPost: PostItem? = nil
    /// All replies in depth-first order (unfiltered, unsorted)
    @State private var allReplies: [ThreadReply] = []
    @State private var isLoading = true
    @State private var error: Error? = nil
    @State private var threadViewModel: TimelineViewModel?
    @State private var showRootReplyComposer = false
    /// Handle of a mentioned user — used to programmatically push a ProfileView
    @State private var mentionedHandle: String? = nil
    /// Current sort order for top-level replies
    @State private var sortOrder: ReplySortOrder = .time

    /// Set of post URIs whose sub-threads are collapsed
    @State private var collapsed: Set<String> = []

    /// The URI of the post the user actually tapped — highlighted in the list
    @State private var focusedPostURI: String? = nil
    /// Tracks whether the root post is visible — used to show/hide the scroll-to-top FAB.
    @State private var isAtTop: Bool = true

    // ── Image viewer sheet ──
    @State private var viewerImages: [AppBskyLexicon.Embed.ImagesDefinition.ViewImage] = []
    @State private var viewerStartIndex: Int = 0
    @State private var showImageViewer: Bool = false

    // MARK: - Sorted + visible replies
    // Sorting reorders depth-0 nodes; their subtrees follow them in depth-first order.
    private var sortedReplies: [ThreadReply] {
        guard sortOrder == .hot else { return allReplies }

        // Separate depth-0 roots from deeper nodes
        // Each root carries its full subtree (contiguous block in depth-first order).
        var roots: [(root: ThreadReply, subtree: [ThreadReply])] = []
        var i = 0
        while i < allReplies.count {
            let node = allReplies[i]
            if node.depth == 0 {
                var subtree: [ThreadReply] = []
                var j = i + 1
                while j < allReplies.count, allReplies[j].depth > 0 {
                    subtree.append(allReplies[j])
                    j += 1
                }
                roots.append((root: node, subtree: subtree))
                i = j
            } else {
                i += 1
            }
        }

        // Sort roots by likeCount descending; subtrees stay attached
        let sorted = roots.sorted { $0.root.post.likeCount > $1.root.post.likeCount }
        return sorted.flatMap { [$0.root] + $0.subtree }
    }

    private var visibleReplies: [ThreadReply] {
        let base = sortedReplies
        guard !collapsed.isEmpty else { return base }

        var result: [ThreadReply] = []
        var skipUntilDepth: Int? = nil

        for reply in base {
            if let skipDepth = skipUntilDepth {
                if reply.depth > skipDepth { continue }
                else { skipUntilDepth = nil }
            }
            result.append(reply)
            if collapsed.contains(reply.id) && reply.hasChildren {
                skipUntilDepth = reply.depth
            }
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Top anchor — its onAppear/onDisappear drive the scroll-to-top FAB.
                    Color.clear
                        .frame(height: 0)
                        .id("__threadTop__")
                        .onAppear  { Task { @MainActor in isAtTop = true  } }
                        .onDisappear { Task { @MainActor in isAtTop = false } }

                    if isLoading {
                        LoadingView(message: "Loading thread…")
                            .padding(.top, AtmoTheme.Spacing.xxl)
                    } else if let error = error {
                        ErrorBannerView(message: error.localizedDescription, onRetry: {
                            Task { await loadThread() }
                        })
                        .padding()
                    } else if let root = rootPost, let vm = threadViewModel {

                        // ── Root post ──
                        RootPostView(
                            post: root,
                            viewModel: vm,
                            onMentionTap: { handle in
                                mentionedHandle = handle
                            },
                            onImageTap: { images, index in
                                viewerImages = images
                                viewerStartIndex = index
                                showImageViewer = true
                            }
                        )

                        Divider()
                            .overlay(Color.secondary.opacity(0.12))

                        // ── Sort header (only shown when there are replies) ──
                        if !allReplies.isEmpty {
                            ReplySortHeader(sortOrder: $sortOrder, replyCount: allReplies.count)
                                .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
                                .padding(.vertical, AtmoTheme.Spacing.sm)

                            Divider()
                                .overlay(Color.secondary.opacity(0.08))
                        }

                        // ── Replies ──
                        let visible = visibleReplies
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, reply in
                            let isLast = index == visible.count - 1
                            let nextDepth = isLast ? -1 : visible[index + 1].depth
                            let continuesBelow = nextDepth > reply.depth
                            let isCollapsed = collapsed.contains(reply.id)
                            let isFocused = focusedPostURI == reply.post.uri

                            ReplyRowView(
                                reply: reply,
                                viewModel: vm,
                                continuesBelow: continuesBelow,
                                isCollapsed: isCollapsed,
                                isFocused: isFocused,
                                onToggleCollapse: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if collapsed.contains(reply.id) {
                                            collapsed.remove(reply.id)
                                        } else {
                                            collapsed.insert(reply.id)
                                        }
                                    }
                                },
                                onMentionTap: { handle in
                                    mentionedHandle = handle
                                },
                                onImageTap: { images, index in
                                    viewerImages = images
                                    viewerStartIndex = index
                                    showImageViewer = true
                                }
                            )
                            .id(reply.post.uri)
                        }

                        if allReplies.isEmpty {
                            Text("No replies yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, AtmoTheme.Spacing.xxl)
                        }

                        Color.clear.frame(height: 88)
                    }
                }
            }
            .onChange(of: focusedPostURI) { _, uri in
                if let uri {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo(uri, anchor: .center)
                        }
                    }
                }
            }

            // ── FAB column (inside ScrollViewReader so proxy is in scope) ──
            if rootPost != nil, !isLoading {
                VStack(spacing: AtmoTheme.Spacing.md) {
                    // Scroll-to-top — only visible once the user has scrolled past the root post
                    if !isAtTop {
                        ScrollToTopButton {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                proxy.scrollTo("__threadTop__", anchor: .top)
                            }
                        }
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isAtTop)
                    }

                    ReplyFAB {
                        showRootReplyComposer = true
                    }
                }
                .padding(.trailing, AtmoTheme.Spacing.xxl)
                .padding(.bottom, AtmoTheme.Spacing.xxl)
            }
        } // end ZStack
        } // end ScrollViewReader
        .navigationTitle("Thread")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
#endif
        // Allow tapping a quoted/embedded post inside a thread to push another ThreadView.
        .navigationDestination(for: PostNavTarget.self) { target in
            ThreadView(postURI: target.uri)
        }
        // Programmatic push when a @mention is tapped anywhere in the thread.
        .overlay {
            if let handle = mentionedHandle {
                NavigationLink(value: handle, label: { EmptyView() })
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: mentionedHandle) { _, handle in
            if handle != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    mentionedHandle = nil
                }
            }
        }
        .sheet(isPresented: $showRootReplyComposer) {
            if let root = rootPost {
                ComposerView(replyTo: root, onSuccess: {
                    insertOptimisticReply(makeOptimisticReply(replyingToURI: root.uri, depth: 0, parentID: nil), parentURI: nil)
                    // Reload in the background to replace the optimistic entry with the real one
                    Task { try? await Task.sleep(for: .seconds(1)); await loadThread() }
                })
            }
        }
        .sheet(isPresented: $showImageViewer) {
            ImageViewerView(images: viewerImages, selectedIndex: $viewerStartIndex)
        }
        .task {
            threadViewModel = TimelineViewModel(service: service)
            await loadThread()
        }
    }

    // MARK: - Optimistic Reply Insertion

    /// Builds a synthetic `ThreadReply` using the current user's session info.
    /// The URI is a placeholder — it will be replaced when `loadThread()` refreshes.
    private func makeOptimisticReply(replyingToURI: String, depth: Int, parentID: String?) -> ThreadReply {
        let item = PostItem(
            pendingURI: "pending://\(UUID().uuidString)",
            handle: service.currentHandle ?? "you",
            text: ""
        )
        return ThreadReply(post: item, depth: depth, hasChildren: false, parentID: parentID, isPending: true)
    }

    /// Inserts an optimistic reply at the correct position in `allReplies`.
    /// - `parentURI`: nil for root-level replies; the URI of the replied-to post for nested replies.
    private func insertOptimisticReply(_ reply: ThreadReply, parentURI: String?) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            if parentURI == nil {
                // Root-level reply — prepend before other depth-0 entries
                // so "Time" sort shows it first; "Hot" sort will push it down by likes anyway.
                if let firstDepthZero = allReplies.firstIndex(where: { $0.depth == 0 }) {
                    allReplies.insert(reply, at: firstDepthZero)
                } else {
                    allReplies.append(reply)
                }
            } else {
                // Nested reply — insert immediately after the parent post's last descendant
                if let parentIdx = allReplies.firstIndex(where: { $0.post.uri == parentURI }) {
                    // Find the end of this parent's subtree
                    var insertAt = parentIdx + 1
                    let parentDepth = allReplies[parentIdx].depth
                    while insertAt < allReplies.count, allReplies[insertAt].depth > parentDepth {
                        insertAt += 1
                    }
                    allReplies.insert(reply, at: insertAt)
                    // Mark parent as having children
                    allReplies[parentIdx].hasChildren = true
                } else {
                    allReplies.append(reply)
                }
            }
        }
    }

    // MARK: - Load Thread
    private func loadThread() async {
        guard let kit = service.atProtoKit else { return }
        isLoading = allReplies.isEmpty // only show spinner on cold load, not background refresh
        error = nil
        do {
            let initial = try await kit.getPostThread(from: postURI)
            guard case .threadViewPost(let initialThread) = initial.thread else {
                isLoading = false; return
            }

            let rootURI = findRootURI(from: initialThread)
            let rootThread: AppBskyLexicon.Feed.ThreadViewPostDefinition
            if rootURI == postURI {
                rootThread = initialThread
            } else {
                let rootOutput = try await kit.getPostThread(from: rootURI)
                guard case .threadViewPost(let rt) = rootOutput.thread else {
                    isLoading = false; return
                }
                rootThread = rt
            }

            let rootPostItem = PostItem(postView: rootThread.post)
            rootPost = rootPostItem
            focusedPostURI = (postURI == rootURI) ? nil : postURI

            var collected: [ThreadReply] = []
            collectReplies(from: rootThread.replies, depth: 0, parentID: nil, into: &collected)
            for i in collected.indices {
                collected[i].hasChildren = collected.contains(where: { $0.parentID == collected[i].id })
            }
            // Replace list — removes any pending optimistic entries automatically
            allReplies = collected

            // Seed the threadViewModel with all posts so toggleLike / toggleRepost
            // can find them by ID. Without this the ViewModel's posts array is empty
            // and all like/repost actions silently no-op.
            threadViewModel?.seedPosts([rootPostItem] + collected.map { $0.post })
        } catch {
            self.error = error
        }
        isLoading = false
    }

    private func findRootURI(from thread: AppBskyLexicon.Feed.ThreadViewPostDefinition) -> String {
        var current = thread
        while let parentUnion = current.parent,
              case .threadViewPost(let parentThread) = parentUnion {
            current = parentThread
        }
        return current.post.uri
    }

    private func collectReplies(
        from nodes: [AppBskyLexicon.Feed.ThreadViewPostDefinition.RepliesUnion]?,
        depth: Int,
        parentID: String?,
        into collected: inout [ThreadReply]
    ) {
        guard let nodes else { return }
        for node in nodes {
            guard case .threadViewPost(let thread) = node else { continue }
            let item = PostItem(postView: thread.post)
            collected.append(ThreadReply(post: item, depth: depth, parentID: parentID))
            collectReplies(from: thread.replies, depth: depth + 1, parentID: item.id, into: &collected)
        }
    }
}

// MARK: - Reply Sort Header
private struct ReplySortHeader: View {
    @Binding var sortOrder: ReplySortOrder
    let replyCount: Int

    var body: some View {
        HStack {
            Text("\(replyCount) \(replyCount == 1 ? "reply" : "replies")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            // Segmented sort picker
            HStack(spacing: 2) {
                ForEach(ReplySortOrder.allCases) { order in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            sortOrder = order
                        }
                    } label: {
                        Label(order.rawValue, systemImage: order.icon)
                            .font(.caption.weight(.medium))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, AtmoTheme.Spacing.sm)
                            .padding(.vertical, 5)
                            .foregroundStyle(sortOrder == order ? .white : .secondary)
                            .background {
                                if sortOrder == order {
                                    Capsule()
                                        .fill(AtmoColors.skyBlue)
                                } else {
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.10))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: sortOrder)
                }
            }
        }
    }
}

// MARK: - Root Post (expanded)
private struct RootPostView: View {
    let post: PostItem
    let viewModel: TimelineViewModel
    var onMentionTap: ((String) -> Void)? = nil
    var onImageTap: (([AppBskyLexicon.Embed.ImagesDefinition.ViewImage], Int) -> Void)? = nil

    @Environment(\.hashtagSearch) private var hashtagSearch

    private var livePost: PostItem {
        viewModel.posts.first(where: { $0.id == post.id }) ?? post
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AtmoTheme.Spacing.md) {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                NavigationLink(value: livePost.authorDID) {
                    AvatarView(url: livePost.authorAvatarURL, size: avatarSize)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    if let name = livePost.authorDisplayName {
                        Text(name).font(AtmoFonts.authorName)
                    }
                    Text("@\(livePost.authorHandle)")
                        .font(AtmoFonts.authorHandle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(livePost.indexedAt.atmoFormatted())
                    .font(AtmoFonts.timestamp)
                    .foregroundStyle(.tertiary)
            }

            if !livePost.text.isEmpty {
                RichTextView(
                    text: livePost.displayText,
                    facets: livePost.facets,
                    onMentionTap: { handle in onMentionTap?(handle) },
                    onHashtagTap: { tag in hashtagSearch(tag) }
                )
                .font(.body)

                if TranslationHelper.needsTranslation(livePost.displayText) {
                    TranslateButton(text: livePost.displayText)
                }
            }

            if let embed = livePost.embed {
                PostEmbedView(embed: embed, onImageTap: onImageTap)
            }

            HStack(spacing: AtmoTheme.Spacing.xl) {
                statLabel(count: livePost.replyCount, label: "replies")
                statLabel(count: livePost.repostCount, label: "reposts")
                statLabel(count: livePost.likeCount, label: "likes")
                statLabel(count: livePost.quoteCount, label: "quotes")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Divider().overlay(AtmoColors.glassDivider)

            // showBookmark: true — only the root/parent post of a thread can be bookmarked
            PostActionsView(post: livePost, viewModel: viewModel, showBookmark: true)
        }
        .padding(AtmoTheme.Feed.horizontalPadding)
        .navigationDestination(for: String.self) { did in
            ProfileView(actorDID: did)
        }
    }

    private func statLabel(count: Int, label: String) -> some View {
        HStack(spacing: 3) {
            Text(count.formatted(.number.notation(.compactName)))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text(label)
        }
    }
}

// MARK: - Reply Row
private struct ReplyRowView: View {
    let reply: ThreadReply
    let viewModel: TimelineViewModel
    let continuesBelow: Bool
    let isCollapsed: Bool
    let isFocused: Bool
    let onToggleCollapse: () -> Void
    var onMentionTap: ((String) -> Void)? = nil
    var onImageTap: (([AppBskyLexicon.Embed.ImagesDefinition.ViewImage], Int) -> Void)? = nil

    @Environment(ATProtoService.self) private var service
    @Environment(\.hashtagSearch) private var hashtagSearch

    private var livePost: PostItem {
        viewModel.posts.first(where: { $0.id == reply.post.id }) ?? reply.post
    }

    private var avatarLeading: CGFloat {
        AtmoTheme.Feed.horizontalPadding + CGFloat(reply.depth) * indentStep
    }
    private var avatarCenterX: CGFloat {
        avatarLeading + replyAvatarSize / 2
    }
    private var parentAvatarCenterX: CGFloat {
        AtmoTheme.Feed.horizontalPadding + CGFloat(reply.depth - 1) * indentStep + replyAvatarSize / 2
    }

    var body: some View {
        ZStack(alignment: .topLeading) {

            // ── Curved connector from parent avatar ──
            if reply.depth > 0 {
                CurvedConnector(fromX: parentAvatarCenterX, toX: avatarCenterX, lineWidth: lineWidth)
                    .stroke(
                        Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    // Tall enough frame so the cubic Bézier loop has room to arc
                    // smoothly. rect.midY (= connectorHeight / 2) is where the
                    // horizontal arm meets the child avatar center.
                    .frame(height: connectorHeight)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            // ── Vertical continuation line ──
            // Starts just below this row's avatar bottom edge so it connects
            // down to the child row's CurvedConnector (which begins at y = -1).
            if continuesBelow && !isCollapsed {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: lineWidth)
                    .padding(.leading, avatarCenterX - lineWidth / 2)
                    .padding(.top, replyAvatarSize + AtmoTheme.Spacing.xs)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            // ── Reply content ──
            VStack(alignment: .leading, spacing: 0) {

                // Header: avatar + author + timestamp + collapse button
                HStack(alignment: .top, spacing: AtmoTheme.Spacing.sm) {
                    Spacer().frame(width: avatarLeading)

                    // Pending replies show the current user's avatar with a spinner overlay
                    if reply.isPending {
                        ZStack {
                            AvatarView(url: nil, size: replyAvatarSize)
                            ProgressView()
                                .scaleEffect(0.5)
                                .tint(.white)
                        }
                    } else {
                        NavigationLink(value: livePost.authorDID) {
                            AvatarView(url: livePost.authorAvatarURL, size: replyAvatarSize)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: AtmoTheme.Spacing.xs) {
                            if reply.isPending {
                                Text(service.currentHandle.map { "@\($0)" } ?? "You")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text("Sending…")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                if let name = livePost.authorDisplayName {
                                    Text(name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                }
                                Text("@\(livePost.authorHandle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(livePost.indexedAt.atmoFormatted())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    // ── Collapse / Expand button ──
                    if reply.hasChildren && !reply.isPending {
                        Button(action: onToggleCollapse) {
                            Image(systemName: isCollapsed ? "plus" : "minus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .background {
                                    Circle()
                                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                                        .background(Circle().fill(.ultraThinMaterial))
                                }
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, AtmoTheme.Feed.horizontalPadding)
                    }
                }

                // Body
                if !isCollapsed {
                    let bodyInset = avatarLeading + replyAvatarSize + AtmoTheme.Spacing.sm
                    VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                        if reply.isPending {
                            // Skeleton placeholder while the reply is in-flight
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                                .frame(maxWidth: .infinity)
                                .frame(height: 12)
                                .padding(.trailing, AtmoTheme.Feed.horizontalPadding)
                        } else {
                            if !livePost.displayText.isEmpty {
                                RichTextView(
                                    text: livePost.displayText,
                                    facets: livePost.facets,
                                    onMentionTap: { handle in onMentionTap?(handle) },
                                    onHashtagTap: { tag in hashtagSearch(tag) }
                                )
                                .font(.subheadline)

                                if TranslationHelper.needsTranslation(livePost.displayText) {
                                    TranslateButton(text: livePost.displayText)
                                }
                            }

                            if let embed = livePost.embed {
                                PostEmbedView(embed: embed, onImageTap: onImageTap)
                            }

                            // Actions row
                            PostActionsView(post: livePost, viewModel: viewModel)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.leading, bodyInset)
                    .padding(.trailing, reply.isPending ? 0 : AtmoTheme.Feed.horizontalPadding)
                    .padding(.top, AtmoTheme.Spacing.xs)
                    .padding(.bottom, AtmoTheme.Spacing.md)
                } else {
                    if reply.hasChildren {
                        Text("Thread collapsed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, avatarLeading + replyAvatarSize + AtmoTheme.Spacing.sm)
                            .padding(.bottom, AtmoTheme.Spacing.sm)
                    }
                }
            }
        }
        .background(
            reply.isPending
                ? AtmoColors.skyBlue.opacity(0.04)
                : isFocused ? AtmoColors.skyBlue.opacity(0.07) : Color.clear
        )
        .overlay(alignment: .leading) {
            // Subtle left accent line on pending replies
            if reply.isPending {
                Rectangle()
                    .fill(AtmoColors.skyBlue.opacity(0.4))
                    .frame(width: 2)
            }
        }
    }
}

// MARK: - Curved Connector Shape
// Draws an L-shaped connector with a smooth rounded corner from the parent
// avatar column (fromX) down to the child avatar centre (toX, rect.midY).
//
// Frame height = connectorHeight = replyAvatarSize = 32 pt, so rect.midY = 16 pt
// which is exactly the vertical centre of the child avatar.
//
// The path:
//   • Starts at (fromX, -lineWidth/2) — overlaps the parent's continuation
//     line by half a stroke so there is no visible gap between rows.
//   • Drops vertically to the turn point.
//   • Rounds the corner with a cubic Bézier whose control points pull the
//     curve first downward then rightward, producing a smooth elbow.
//   • Ends at (toX, endY) — the child avatar centre.
private struct CurvedConnector: Shape {
    let fromX: CGFloat
    let toX: CGFloat
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()

        // Overlap the parent row's continuation line so there is no gap.
        let startY: CGFloat = -lineWidth / 2

        // Horizontal arm lands at the child avatar's vertical centre.
        let endY: CGFloat = rect.midY

        // Corner radius for the elbow — capped so it fits within the frame.
        let r: CGFloat = min(8, endY - startY, toX - fromX)

        // Straight vertical segment, stopping one radius before the bend.
        let turnY = endY - r

        p.move(to: CGPoint(x: fromX, y: startY))
        p.addLine(to: CGPoint(x: fromX, y: turnY))

        // Rounded elbow: cubic Bézier from (fromX, turnY) → (fromX+r, endY).
        // cp1 keeps the path vertical as it enters the curve;
        // cp2 keeps it horizontal as it exits — producing a clean quarter-circle feel.
        p.addCurve(
            to:       CGPoint(x: fromX + r, y: endY),
            control1: CGPoint(x: fromX,     y: endY),
            control2: CGPoint(x: fromX + r, y: endY)
        )

        // Horizontal arm to the child avatar centre.
        p.addLine(to: CGPoint(x: toX, y: endY))

        return p
    }
}

// MARK: - Reply FAB
private struct ReplyFAB: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(AtmoColors.skyBlue)
                .frame(width: 56, height: 56)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
        }
        .buttonStyle(ReplyFABButtonStyle())
        .atmoShadow(AtmoTheme.Shadow.floating)
    }
}

private struct ReplyFABButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
