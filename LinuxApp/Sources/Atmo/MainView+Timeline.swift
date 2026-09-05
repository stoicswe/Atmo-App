import Adwaita
import CAdw
import Foundation
import AtmoCore

extension MainView {

    /// Value snapshot of a PostItem for Adwaita's ForEach (the core model
    /// carries ATProtoKit types the view layer doesn't need — embeds come
    /// pre-digested as `EmbedContent`, rich text as Pango markup built
    /// from core `RichText.segments`).
    struct PostRowSnapshot: Identifiable, Equatable {
        struct Ancestor: Identifiable, Equatable {
            let id: String
            let author: String
            let avatarURL: URL?
            let text: String
        }

        let id: String
        let authorDID: String
        let author: String
        let handle: String
        let isVerified: Bool
        let avatarURL: URL?
        let time: String
        let text: String
        let markup: String
        let embed: EmbedContent?
        let webURL: String?
        let repostedBy: String?
        /// The root and parent the feed embeds for a reply (compact inline
        /// rows with a rail, like the Apple feed).
        let ancestors: [Ancestor]
        let likeCount: Int
        let repostCount: Int
        let replyCount: Int
        let isLiked: Bool
        let isReposted: Bool
        let isQuoted: Bool
        let isBookmarked: Bool
        let isGhost: Bool
        let ghostRemaining: String?

        init(post: PostItem) {
            var repostedBy: String? = nil
            if case .repost(_, let byHandle, let byDisplayName, _) = post.reason {
                repostedBy = byDisplayName ?? byHandle
            }
            self.id = post.uri
            self.authorDID = post.authorDID
            self.author = post.authorDisplayName ?? post.authorHandle
            self.handle = post.authorHandle
            self.isVerified = post.authorVerification != nil
            self.avatarURL = post.authorAvatarURL
            self.time = post.createdAt.atmoFormatted()
            self.text = post.displayText
            self.markup = RichTextMarkup.markup(for: post.richTextSegments)
            self.embed = post.embedContent
            self.webURL = post.bskyWebURL?.absoluteString
            self.repostedBy = repostedBy
            self.ancestors = post.threadAncestors.map {
                Ancestor(
                    id: $0.uri,
                    author: $0.authorDisplayName ?? "@\($0.authorHandle)",
                    avatarURL: $0.authorAvatarURL,
                    text: $0.displayText
                )
            }
            self.likeCount = post.likeCount
            self.repostCount = post.repostCount
            self.replyCount = post.replyCount
            self.isLiked = post.isLiked
            self.isReposted = post.isReposted
            self.isQuoted = post.isQuoted
            self.isBookmarked = onMain { BookmarkStore.shared.isBookmarked(post) }
            let ghost = GhostPostPolicy.isGhost(post)
            self.isGhost = ghost
            self.ghostRemaining = ghost
                ? GhostPostPolicy.remainingText(until: GhostPostPolicy.expiresAt(post))
                : nil
        }
    }

    var timelineRows: [PostRowSnapshot] {
        _ = tick
        return onMain {
            (AppSession.shared.timeline?.posts ?? []).map(PostRowSnapshot.init(post:))
        }
    }

    var timelineIsLoading: Bool {
        _ = tick
        return onMain { AppSession.shared.timeline?.isLoading ?? false }
    }

    var timelineCanLoadMore: Bool {
        _ = tick
        return onMain { AppSession.shared.timeline?.canLoadMore ?? false }
    }

    var timelineNewPostsCount: Int {
        _ = tick
        return onMain { AppSession.shared.timeline?.newPostsCount ?? 0 }
    }

    var timelineFeedName: String {
        _ = tick
        return onMain { AppSession.shared.timeline?.feedSource.displayName ?? "Home" }
    }

    var timelineIsFollowing: Bool {
        _ = tick
        return onMain { AppSession.shared.timeline?.feedSource.isFollowing ?? true }
    }

    var timelineFeedURI: String? {
        _ = tick
        return onMain {
            if case .custom(let uri, _) = AppSession.shared.timeline?.feedSource { return uri }
            return nil
        }
    }

    var infiniteScrollEnabled: Bool {
        _ = tick
        return FeedPreferences.infiniteScrollEnabled
    }

    // MARK: - Timeline pane

    @ViewBuilder var timelinePane: Body {
        let rows = timelineRows
        VStack(spacing: 0) {
            // GNOME's banner in place of the macOS "new posts" pill: the
            // silent refresh prepends posts; the banner counts the unseen
            // ones and jumps to them.
            Banner(newPostsBannerTitle, visible: timelineNewPostsCount > 0)
                .button("Show") { showNewPosts() }
            if rows.isEmpty {
                if timelineIsLoading {
                    Spinner()
                        .vexpand()
                        .valign(.center)
                } else {
                    StatusPage(
                        "No posts yet",
                        icon: .custom(name: "user-home-symbolic"),
                        description: "Pull the timeline with the refresh button."
                    )
                    .vexpand()
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.id) { row in
                            postRow(row, actions: .timeline)
                            Separator()
                        }
                        loadMoreFooter(visible: timelineCanLoadMore, loading: timelineIsLoading) {
                            loadMoreTimeline()
                        }
                    }
                    .frame(maxWidth: 720)
                }
                .vexpand()
                .scrollToTop(on: $timelineScrollTop)
                .onBottomEdgeReached {
                    guard infiniteScrollEnabled else { return }
                    loadMoreTimeline()
                }
            }
        }
    }

    var newPostsBannerTitle: String {
        let count = timelineNewPostsCount
        return count == 1 ? "1 new post" : "\(count) new posts"
    }

    func showNewPosts() {
        timelineScrollTop.signal()
        onMain { AppSession.shared.timeline?.clearNewPostsCount() }
        tick += 1
    }

    /// "Load More" is the paging control when infinite scroll is off
    /// (Settings → Feed); with it on, the button doubles as a fallback
    /// and shows the paging spinner.
    @ViewBuilder func loadMoreFooter(visible: Bool, loading: Bool, action: @escaping () -> Void) -> Body {
        if loading {
            Spinner()
                .padding(12)
        } else if visible {
            Button("Load More", handler: action)
                .flat()
                .padding(8)
        }
    }

    /// Pin/unpin and unsubscribe for the custom feed on screen, like the
    /// macOS feed subscription bar.
    @ViewBuilder var timelineHeaderActions: Body {
        // Conditional bodies become a vertical box inside the header bar;
        // an explicit HStack keeps the buttons in the row.
        HStack(spacing: 0) {
            if let uri = timelineFeedURI {
                let pinned = onMain { SavedFeedsStore.shared.isPinned(uri: uri) }
                Button(icon: .custom(name: "view-pin-symbolic")) {
                    runCore { await SavedFeedsStore.shared.setPinned(!pinned, uri: uri, service: AppSession.shared.service) }
                }
                .tooltip(pinned ? "Unpin feed" : "Pin feed")
                .flat()
                .style("accent", active: pinned)
                Button(icon: .custom(name: "list-remove-symbolic")) { unsubscribeCurrentFeed(uri: uri) }
                    .tooltip("Unsubscribe")
                    .flat()
            }
        }
    }

    func unsubscribeCurrentFeed(uri: String) {
        runCore {
            await SavedFeedsStore.shared.unsubscribe(uri: uri, service: AppSession.shared.service)
            await AppSession.shared.timeline?.setFeedSource(.following)
        }
        sidebarSelection = PaneID.home
        showToast("Unsubscribed")
    }

    // MARK: - Post row (shared by timeline, search results, thread, profile pages)

    /// Where a row's like/repost taps land.
    enum RowActions: Equatable {
        case timeline
        case thread(uri: String)
        case profile(key: String)
        case search
        case readOnly
    }

    @ViewBuilder func postRow(_ row: PostRowSnapshot, actions: RowActions, showsAncestors: Bool = true) -> Body {
        VStack(spacing: 0) {
            if showsAncestors {
                ForEach(row.ancestors, id: \.id) { ancestor in
                    ancestorRow(ancestor)
                }
            }
            HStack(spacing: 10) {
                remoteAvatar(url: row.avatarURL, name: row.author, size: 42)
                    .valign(.start)
                    .padding(2)
                    .onClick { openProfile(actor: row.authorDID) }
                    .tooltip("View profile")
                VStack(spacing: 4) {
                    if let repostedBy = row.repostedBy {
                        Text("↻ Reposted by \(repostedBy)")
                            .style("dim-label")
                            .style("caption")
                            .halign(.start)
                    }
                    HStack(spacing: 6) {
                        Text(row.author)
                            .ellipsize()
                            .style("heading")
                            .halign(.start)
                            .onClick { openProfile(actor: row.authorDID) }
                        if row.isVerified {
                            Symbol(icon: .custom(name: "atmo-verified-symbolic"))
                                .style("accent")
                                .tooltip("Verified")
                        }
                        Text("@\(row.handle)")
                            .ellipsize()
                            .style("dim-label")
                            .halign(.start)
                        Text(row.time)
                            .style("dim-label")
                            .style("caption")
                            .hexpand()
                            .halign(.end)
                    }
                    if row.isGhost, let remaining = row.ghostRemaining {
                        Text("👻 Ghost · \(remaining)")
                            .style("caption")
                            .style("dim-label")
                            .halign(.start)
                    }
                    if !row.text.isEmpty {
                        richTextLabel(row.markup)
                            .onClick {
                                guard !LinkClickGuard.shouldSwallowRowClick else { return }
                                openThread(uri: row.id)
                            }
                    }
                    if let embed = row.embed {
                        embedView(embed, webURL: row.webURL)
                    }
                    actionBar(row, actions: actions)
                }
                .hexpand()
            }
            .padding(10)
        }
    }

    /// A post's body text with tappable mentions, hashtags, and links.
    func richTextLabel(_ markup: String) -> AnyView {
        Text(markup)
            .useMarkup()
            .wrap()
            .xalign(0)
            .halign(.start)
            .onActivateLink { uri in handleLink(uri) }
    }

    /// Compact inline row for the root/parent a reply is attached to,
    /// with a rail down to the reply.
    @ViewBuilder func ancestorRow(_ ancestor: PostRowSnapshot.Ancestor) -> Body {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                remoteAvatar(url: ancestor.avatarURL, name: ancestor.author, size: 28)
                    .padding(2)
                Separator()
                    .style("rail")
                    .vexpand()
                    .halign(.center)
            }
            .valign(.fill)
            VStack(spacing: 2) {
                Text(ancestor.author)
                    .ellipsize()
                    .style("caption-heading")
                    .halign(.start)
                Text(ancestor.text.isEmpty ? "(media)" : ancestor.text)
                    .ellipsize()
                    .lines(2)
                    .wrap()
                    .style("dim-label")
                    .halign(.start)
            }
            .hexpand()
        }
        .padding(10, .horizontal)
        .padding(6, .top)
        .onClick { openThread(uri: ancestor.id) }
    }

    // MARK: - Action bar

    @ViewBuilder func actionBar(_ row: PostRowSnapshot, actions: RowActions) -> Body {
        HStack(spacing: 4) {
            switch actions {
            case .readOnly:
                countLabel("mail-reply-sender-symbolic", row.replyCount)
                countLabel("atmo-repost-symbolic", row.repostCount)
                countLabel("atmo-heart-symbolic", row.likeCount)
            default:
                Button(icon: .custom(name: "mail-reply-sender-symbolic")) {
                    replyTo(uri: row.id, actions: actions)
                }
                .flat()
                .tooltip("Reply")
                Text("\(row.replyCount)")
                    .style("dim-label")
                    .style("caption")
                if !row.isGhost {
                    Button(icon: .custom(name: "atmo-repost-symbolic")) {
                        repostMenuURI = row.id
                    }
                    .flat()
                    .style("success", active: row.isReposted || row.isQuoted)
                    .tooltip(row.isReposted ? "Reposted" : "Repost or quote")
                    .popover(visible: repostMenuBinding(row.id)) {
                        repostMenu(row, actions: actions)
                    }
                    Text("\(row.repostCount)")
                        .style("dim-label")
                        .style("caption")
                    Button(icon: .custom(name: row.isLiked ? "atmo-heart-filled-symbolic" : "atmo-heart-symbolic")) {
                        toggleLike(uri: row.id, actions: actions)
                    }
                    .flat()
                    .style("error", active: row.isLiked)
                    .tooltip(row.isLiked ? "Unlike" : "Like")
                    Text("\(row.likeCount)")
                        .style("dim-label")
                        .style("caption")
                    Button(icon: .custom(name: "mail-send-symbolic")) {
                        openSendPost(uri: row.id, actions: actions)
                    }
                    .flat()
                    .tooltip("Send post in a message")
                }
            }
            Button(icon: .custom(name: row.isBookmarked ? "user-bookmarks-symbolic" : "bookmark-new-symbolic")) {
                toggleBookmark(uri: row.id, actions: actions)
            }
            .flat()
            .style("accent", active: row.isBookmarked)
            .tooltip(row.isBookmarked ? "Remove bookmark" : "Bookmark")
            .hexpand()
            .halign(.end)
            Button(icon: .custom(name: "view-more-symbolic")) {
                moreMenuURI = row.id
            }
            .flat()
            .tooltip("More")
            .popover(visible: moreMenuBinding(row.id)) {
                moreMenu(row)
            }
        }
    }

    @ViewBuilder func countLabel(_ icon: String, _ count: Int) -> Body {
        HStack(spacing: 4) {
            Symbol(icon: .custom(name: icon))
                .style("dim-label")
            Text("\(count)")
                .style("dim-label")
                .style("caption")
        }
        .padding(6, .horizontal)
    }

    func repostMenuBinding(_ uri: String) -> Binding<Bool> {
        Binding(
            get: { repostMenuURI == uri },
            set: { open in if open { repostMenuURI = uri } else if repostMenuURI == uri { repostMenuURI = nil } }
        )
    }

    func moreMenuBinding(_ uri: String) -> Binding<Bool> {
        Binding(
            get: { moreMenuURI == uri },
            set: { open in if open { moreMenuURI = uri } else if moreMenuURI == uri { moreMenuURI = nil } }
        )
    }

    /// Repost / Quote Post, like the macOS popover.
    @ViewBuilder func repostMenu(_ row: PostRowSnapshot, actions: RowActions) -> Body {
        VStack(spacing: 4) {
            Button(row.isReposted ? "Undo Repost" : "Repost", icon: .custom(name: "atmo-repost-symbolic")) {
                repostMenuURI = nil
                toggleRepost(uri: row.id, actions: actions)
            }
            .flat()
            .halign(.start)
            Button("Quote Post", icon: .custom(name: "format-text-italic-symbolic")) {
                repostMenuURI = nil
                quote(uri: row.id, actions: actions)
            }
            .flat()
            .halign(.start)
        }
        .padding(6)
    }

    @ViewBuilder func moreMenu(_ row: PostRowSnapshot) -> Body {
        VStack(spacing: 4) {
            Button("Open Thread", icon: .custom(name: "atmo-thread-symbolic")) {
                moreMenuURI = nil
                openThread(uri: row.id)
            }
            .flat()
            .halign(.start)
            Button("View Profile", icon: .custom(name: "avatar-default-symbolic")) {
                moreMenuURI = nil
                openProfile(actor: row.authorDID)
            }
            .flat()
            .halign(.start)
            if let webURL = row.webURL {
                Button("Copy Link", icon: .custom(name: "edit-copy-symbolic")) {
                    moreMenuURI = nil
                    Desktop.copy(webURL)
                    showToast("Link copied")
                }
                .flat()
                .halign(.start)
                Button("Open in Browser", icon: .custom(name: "web-browser-symbolic")) {
                    moreMenuURI = nil
                    Desktop.open(webURL)
                }
                .flat()
                .halign(.start)
            }
        }
        .padding(6)
    }

    // MARK: - Embeds

    @ViewBuilder func embedView(_ embed: EmbedContent, webURL: String?) -> Body {
        VStack(spacing: 6) {
            if !embed.images.isEmpty {
                imageGrid(embed.images)
            }
            if let video = embed.video {
                videoEmbed(video, webURL: webURL)
            }
            if let link = embed.externalLink {
                linkCard(link)
            }
            if let quote = embed.quote {
                VStack(spacing: 2) {
                    Text("\(quote.authorDisplayName ?? quote.authorHandle) · @\(quote.authorHandle)")
                        .ellipsize()
                        .style("caption-heading")
                        .halign(.start)
                    if !quote.text.isEmpty {
                        Text(quote.text)
                            .wrap()
                            .lines(6)
                            .ellipsize()
                            .style("dim-label")
                            .halign(.start)
                    }
                }
                .padding(8)
                .style("card")
                .onClick { openThread(uri: quote.uri) }
            }
        }
    }

    /// Thumbnail plus a play pill; tapping either swaps in the inline
    /// GtkVideo streaming the HLS playlist (click-to-play is the GNOME
    /// deviation from the Apple app's always-live muted player). Posts
    /// without a playlist fall back to opening the post on bsky.app.
    /// (No GtkOverlay play badge: adwaita-swift's Overlay never
    /// materializes its main child, so the badge sits below instead.)
    @ViewBuilder func videoEmbed(_ video: EmbedContent.Video, webURL: String?) -> Body {
        if let playlist = video.playlistURL?.absoluteString, playingVideos.contains(playlist) {
            VideoPlayer(uri: playlist)
                .frame(minHeight: 300)
                .frame(maxHeight: 540)
            Button(icon: .custom(name: "media-playback-stop-symbolic")) {
                playingVideos.remove(playlist)
            }
            .pill()
            .tooltip("Close player")
            .halign(.center)
            .padding(4, .top)
        } else {
            VStack(spacing: 4) {
                if let thumb = video.thumbnailURL {
                    remotePicture(url: thumb, maxHeight: 360)
                }
                Button(icon: .custom(name: "media-playback-start-symbolic")) {
                    playVideo(video, webURL: webURL)
                }
                .child {
                    HStack(spacing: 6) {
                        Symbol(icon: .custom(name: "media-playback-start-symbolic"))
                        Text("Play video")
                    }
                    .padding(4, .horizontal)
                }
                .pill()
                .halign(.center)
            }
        }
    }

    func playVideo(_ video: EmbedContent.Video, webURL: String?) {
        guard let playlist = video.playlistURL?.absoluteString else {
            if let webURL { Desktop.open(webURL) }
            return
        }
        // Without GStreamer + gtk4paintablesink there is nothing to play
        // through — open the post on bsky.app instead and say why.
        guard VideoPlayer.available else {
            showToast("Inline playback needs GStreamer (gstreamer1.0-gtk4) — opening in browser")
            Desktop.open(webURL ?? playlist)
            return
        }
        playingVideos.insert(playlist)
    }

    /// External links as bsky.app-style cards: social image on top, then
    /// title, description, and the site's host. The whole card opens the
    /// article in the browser.
    @ViewBuilder func linkCard(_ link: EmbedContent.ExternalLink) -> Body {
        VStack(spacing: 0) {
            if let thumb = link.thumbnailURL {
                remotePicture(url: thumb, maxHeight: 300)
            }
            VStack(spacing: 3) {
                Text(link.title.isEmpty ? link.uri : link.title)
                    .wrap()
                    .lines(2)
                    .ellipsize()
                    .style("heading")
                    .halign(.start)
                if !link.linkDescription.isEmpty {
                    Text(link.linkDescription)
                        .wrap()
                        .lines(2)
                        .ellipsize()
                        .style("dim-label")
                        .halign(.start)
                }
                HStack(spacing: 4) {
                    Symbol(icon: .custom(name: "web-browser-symbolic"))
                        .pixelSize(12)
                    Text(link.host)
                        .ellipsize()
                        .style("caption")
                }
                .style("dim-label")
                .halign(.start)
                .padding(2, .top)
            }
            .padding(10)
        }
        .style("card")
        .onClick { Desktop.open(link.uri) }
        .tooltip(link.uri)
    }

    /// One image full width, two side by side, three or four in a 2×2.
    @ViewBuilder func imageGrid(_ images: [EmbedContent.ImageItem]) -> Body {
        if images.count == 1, let item = images.first {
            remotePicture(url: item.thumbnailURL, maxHeight: 360)
                .tooltip(item.altText)
                .onClick { openImage(item) }
        } else {
            let rows = stride(from: 0, to: images.count, by: 2).map { Array(images[$0..<min($0 + 2, images.count)]) }
            ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                HStack(spacing: 4) {
                    ForEach(pair.element, id: \.thumbnailURL) { item in
                        remotePicture(url: item.thumbnailURL, maxHeight: 220)
                            .tooltip(item.altText)
                            .hexpand()
                            .onClick { openImage(item) }
                    }
                }
            }
        }
    }

    /// Full-size images open in the system viewer (the Apple app has an
    /// in-app viewer; a GNOME image window is tracked in PORTING.md).
    func openImage(_ item: EmbedContent.ImageItem) {
        Desktop.open(item.fullSizeURL ?? item.thumbnailURL)
    }

    // MARK: - Actions

    func loadMoreTimeline() {
        runCore { await AppSession.shared.timeline?.loadMore() }
    }

    /// The TimelineViewModel owning a row's interactions: the home feed's,
    /// a seeded per-thread/per-profile store, or the search store.
    @MainActor
    func interactions(for actions: RowActions) -> TimelineViewModel? {
        let session = AppSession.shared
        switch actions {
        case .timeline: return session.timeline
        case .thread(let uri): return session.threadSession(for: uri).interactions
        case .profile(let key):
            session.syncProfileInteractions(for: key)
            return session.profileSession(for: key).interactions
        case .search: return session.searchInteractionStore()
        case .readOnly: return nil
        }
    }

    @MainActor
    func post(uri: String, actions: RowActions) -> PostItem? {
        if let model = interactions(for: actions), let post = model.livePost(uri: uri) ?? model.posts.first(where: { $0.uri == uri }) {
            return post
        }
        // Read-only rows (e.g. bookmarks) still need the post for replies.
        let session = AppSession.shared
        return session.timeline?.livePost(uri: uri)
            ?? session.search?.postResults.first { $0.uri == uri }
    }

    /// Opens the compose dialog as a reply to the row's post.
    func replyTo(uri: String, actions: RowActions) {
        guard let post = onMain({ post(uri: uri, actions: actions) }) else { return }
        openComposer(replyTo: post)
    }

    /// Opens the compose dialog quoting the row's post.
    func quote(uri: String, actions: RowActions) {
        guard let post = onMain({ post(uri: uri, actions: actions) }) else { return }
        openComposer(quoting: post, source: actions)
    }

    func toggleLike(uri: String, actions: RowActions) {
        runCore {
            guard let model = interactions(for: actions),
                  let post = model.posts.first(where: { $0.uri == uri }) else { return }
            await model.toggleLike(post: post)
        }
    }

    func toggleRepost(uri: String, actions: RowActions) {
        runCore {
            guard let model = interactions(for: actions),
                  let post = model.posts.first(where: { $0.uri == uri }) else { return }
            await model.toggleRepost(post: post)
        }
    }

    func toggleBookmark(uri: String, actions: RowActions) {
        guard let post = onMain({ post(uri: uri, actions: actions) }) else { return }
        let added = onMain { () -> Bool in
            BookmarkStore.shared.toggle(post)
            return BookmarkStore.shared.isBookmarked(post)
        }
        showToast(added ? "Bookmarked" : "Bookmark removed")
        tick += 1
    }
}
