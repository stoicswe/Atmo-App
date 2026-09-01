import Adwaita
import Foundation
import AtmoCore

extension MainView {

    /// Value snapshot of a PostItem for Adwaita's ForEach (the core model
    /// carries ATProtoKit types the view layer doesn't need — embeds come
    /// pre-digested as `EmbedContent`).
    struct PostRowSnapshot: Identifiable, Equatable {
        let id: String
        let author: String
        let handle: String
        let avatarURL: URL?
        let time: String
        let text: String
        let embed: EmbedContent?
        let webURL: String?
        let repostedBy: String?
        /// Author of the post this one replies to (from the embedded thread
        /// context); full inline parent rows are still TODO — see PORTING.md.
        let replyToAuthor: String?
        let likeCount: Int
        let repostCount: Int
        let replyCount: Int
        let isLiked: Bool
        let isReposted: Bool

        init(post: PostItem) {
            var repostedBy: String? = nil
            if case .repost(_, let byHandle, let byDisplayName, _) = post.reason {
                repostedBy = byDisplayName ?? byHandle
            }
            self.id = post.uri
            // "✔" suffix marks verified accounts (GTK has no inline
            // icon run here; parity with the Apple badge).
            self.author = (post.authorDisplayName ?? post.authorHandle)
                + (post.authorVerification != nil ? " ✔" : "")
            self.handle = post.authorHandle
            self.avatarURL = post.authorAvatarURL
            self.time = post.createdAt.atmoFormatted()
            self.text = post.displayText
            self.embed = post.embedContent
            self.webURL = post.bskyWebURL?.absoluteString
            self.repostedBy = repostedBy
            self.replyToAuthor = post.threadAncestors.last.map {
                $0.authorDisplayName ?? "@\($0.authorHandle)"
            }
            self.likeCount = post.likeCount
            self.repostCount = post.repostCount
            self.replyCount = post.replyCount
            self.isLiked = post.isLiked
            self.isReposted = post.isReposted
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

    @ViewBuilder var homePane: Body {
        switch pane {
        case .timeline: timelinePane
        case .notifications: notificationsPane
        case .search: searchPane
        }
    }

    @ViewBuilder var timelinePane: Body {
        let rows = timelineRows
        if rows.isEmpty {
            if timelineIsLoading {
                Spinner()
                    .vexpand()
                    .valign(.center)
            } else {
                StatusPage(
                    "No posts yet",
                    icon: .custom(name: "view-list-symbolic"),
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
                    Button("Load More") { loadMoreTimeline() }
                        .flat()
                        .padding(8)
                }
            }
            .vexpand()
        }
    }

    // MARK: - Post row (shared by timeline, search results, thread pages)

    /// Where a row's like/repost taps land. Search results are read-only —
    /// SearchViewModel has no interaction toggles (parity gap tracked in
    /// PORTING.md).
    enum RowActions {
        case timeline
        case thread(uri: String)
        case readOnly
    }

    @ViewBuilder func postRow(_ row: PostRowSnapshot, actions: RowActions) -> Body {
        HStack(spacing: 10) {
            remoteAvatar(url: row.avatarURL, name: row.author, size: 40)
                .valign(.start)
                .padding(2)
            VStack(spacing: 4) {
                if let repostedBy = row.repostedBy {
                    Text("↻ Reposted by \(repostedBy)")
                        .style("dim-label")
                        .halign(.start)
                }
                if let replyToAuthor = row.replyToAuthor {
                    Text("↩ Replying to \(replyToAuthor)")
                        .style("dim-label")
                        .halign(.start)
                }
                HStack(spacing: 6) {
                    Text(row.author)
                        .ellipsize()
                        .style("heading")
                        .halign(.start)
                    Text("@\(row.handle)")
                        .ellipsize()
                        .style("dim-label")
                        .halign(.start)
                    Text(row.time)
                        .style("dim-label")
                        .hexpand()
                        .halign(.end)
                }
                if !row.text.isEmpty {
                    Text(row.text)
                        .wrap()
                        .halign(.start)
                        .onClick { openThread(uri: row.id) }
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

    @ViewBuilder func actionBar(_ row: PostRowSnapshot, actions: RowActions) -> Body {
        HStack(spacing: 12) {
            switch actions {
            case .readOnly:
                Text("♥ \(row.likeCount)")
                    .style("dim-label")
                Text("↻ \(row.repostCount)")
                    .style("dim-label")
            case .timeline, .thread:
                Button(icon: .custom(name: row.isLiked ? "emblem-favorite-symbolic" : "emote-love-symbolic")) {
                    toggleLike(uri: row.id, actions: actions)
                }
                .flat()
                .tooltip(row.isLiked ? "Unlike (\(row.likeCount))" : "Like (\(row.likeCount))")
                Text("\(row.likeCount)")
                    .style("dim-label")
                Button(icon: .custom(name: "media-playlist-repeat-symbolic")) {
                    toggleRepost(uri: row.id, actions: actions)
                }
                .flat()
                .tooltip(row.isReposted ? "Undo repost (\(row.repostCount))" : "Repost (\(row.repostCount))")
                Text("\(row.repostCount)")
                    .style("dim-label")
                Button(icon: .custom(name: "mail-reply-sender-symbolic")) {
                    replyTo(uri: row.id, actions: actions)
                }
                .flat()
                .tooltip("Reply")
            }
            Button("💬 \(row.replyCount)") { openThread(uri: row.id) }
                .flat()
                .tooltip("Open thread")
                .hexpand()
                .halign(.end)
        }
    }

    // MARK: - Embeds

    @ViewBuilder func embedView(_ embed: EmbedContent, webURL: String?) -> Body {
        VStack(spacing: 6) {
            ForEach(embed.images, id: \.thumbnailURL) { item in
                remotePicture(url: item.thumbnailURL, maxHeight: 280)
                    .tooltip(item.altText)
            }
            if embed.hasVideo, let webURL {
                LinkButton(uri: webURL)
                    .child {
                        Text("▶ Video — watch on bsky.app")
                            .style("dim-label")
                    }
                    .halign(.start)
            }
            if let link = embed.externalLink {
                LinkButton(uri: link.uri)
                    .child {
                        VStack(spacing: 2) {
                            Text(link.title.isEmpty ? link.uri : link.title)
                                .ellipsize()
                                .style("heading")
                                .halign(.start)
                            if !link.linkDescription.isEmpty {
                                Text(link.linkDescription)
                                    .ellipsize()
                                    .style("dim-label")
                                    .halign(.start)
                            }
                            Text(link.host)
                                .style("caption")
                                .style("dim-label")
                                .halign(.start)
                        }
                        .padding(8)
                    }
                    .style("card")
                    .halign(.start)
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

    // MARK: - Actions

    func loadMoreTimeline() {
        runCore { await AppSession.shared.timeline?.loadMore() }
    }

    /// The TimelineViewModel owning a row's interactions: the home feed's,
    /// or the seeded per-thread store.
    @MainActor
    private func interactions(for actions: RowActions) -> TimelineViewModel? {
        switch actions {
        case .timeline: return AppSession.shared.timeline
        case .thread(let uri): return AppSession.shared.threadSession(for: uri).interactions
        case .readOnly: return nil
        }
    }

    /// Opens the compose dialog as a reply to the row's post.
    func replyTo(uri: String, actions: RowActions) {
        onMain {
            guard let post = interactions(for: actions)?.posts.first(where: { $0.uri == uri })
            else { return }
            openComposer(replyTo: post)
        }
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
}
