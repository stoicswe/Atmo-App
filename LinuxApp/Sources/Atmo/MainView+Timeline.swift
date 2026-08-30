import Adwaita
import Foundation
import AtmoCore

extension MainView {

    /// Value snapshot of a PostItem for Adwaita's ForEach (the core model
    /// carries ATProtoKit types the view layer doesn't need).
    struct PostRowSnapshot: Identifiable, Equatable {
        let id: String
        let author: String
        let handle: String
        let time: String
        let text: String
        let repostedBy: String?
        let likeCount: Int
        let repostCount: Int
        let replyCount: Int
        let isLiked: Bool
        let isReposted: Bool
    }

    var timelineRows: [PostRowSnapshot] {
        _ = tick
        return onMain {
            (AppSession.shared.timeline?.posts ?? []).map { post in
                var repostedBy: String? = nil
                if case .repost(_, let byHandle, let byDisplayName, _) = post.reason {
                    repostedBy = byDisplayName ?? byHandle
                }
                return PostRowSnapshot(
                    id: post.uri,
                    author: post.authorDisplayName ?? post.authorHandle,
                    handle: post.authorHandle,
                    time: post.createdAt.atmoFormatted(),
                    text: post.displayText,
                    repostedBy: repostedBy,
                    likeCount: post.likeCount,
                    repostCount: post.repostCount,
                    replyCount: post.replyCount,
                    isLiked: post.isLiked,
                    isReposted: post.isReposted
                )
            }
        }
    }

    var timelineIsLoading: Bool {
        _ = tick
        return onMain { AppSession.shared.timeline?.isLoading ?? false }
    }

    @ViewBuilder var homePane: Body {
        if pane == .timeline {
            timelinePane
        } else {
            notificationsPane
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
                        postRow(row)
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

    @ViewBuilder func postRow(_ row: PostRowSnapshot) -> Body {
        VStack(spacing: 4) {
            if let repostedBy = row.repostedBy {
                Text("↻ Reposted by \(repostedBy)")
                    .style("dim-label")
                    .halign(.start)
            }
            HStack(spacing: 6) {
                Text(row.author)
                    .style("heading")
                    .halign(.start)
                Text("@\(row.handle)")
                    .style("dim-label")
                    .halign(.start)
                Text(row.time)
                    .style("dim-label")
                    .hexpand()
                    .halign(.end)
            }
            Text(row.text)
                .wrap()
                .halign(.start)
            HStack(spacing: 12) {
                Button(icon: .custom(name: row.isLiked ? "emblem-favorite-symbolic" : "emote-love-symbolic")) {
                    toggleLike(uri: row.id)
                }
                .flat()
                .tooltip(row.isLiked ? "Unlike (\(row.likeCount))" : "Like (\(row.likeCount))")
                Text("\(row.likeCount)")
                    .style("dim-label")
                Button(icon: .custom(name: "media-playlist-repeat-symbolic")) {
                    toggleRepost(uri: row.id)
                }
                .flat()
                .tooltip(row.isReposted ? "Undo repost (\(row.repostCount))" : "Repost (\(row.repostCount))")
                Text("\(row.repostCount)")
                    .style("dim-label")
                Text("💬 \(row.replyCount)")
                    .style("dim-label")
                    .hexpand()
                    .halign(.end)
            }
        }
        .padding(10)
    }

    // MARK: - Actions

    func loadMoreTimeline() {
        runCore { await AppSession.shared.timeline?.loadMore() }
    }

    func toggleLike(uri: String) {
        runCore {
            guard let timeline = AppSession.shared.timeline,
                  let post = timeline.posts.first(where: { $0.uri == uri }) else { return }
            await timeline.toggleLike(post: post)
        }
    }

    func toggleRepost(uri: String) {
        runCore {
            guard let timeline = AppSession.shared.timeline,
                  let post = timeline.posts.first(where: { $0.uri == uri }) else { return }
            await timeline.toggleRepost(post: post)
        }
    }
}
