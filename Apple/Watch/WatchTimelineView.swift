import SwiftUI
import AtmoCore

struct WatchTimelineView: View {
    @Environment(ATProtoService.self) private var service
    @State private var viewModel: TimelineViewModel? = nil

    var body: some View {
        Group {
            if let viewModel {
                if viewModel.posts.isEmpty && viewModel.isLoading {
                    ProgressView()
                } else if viewModel.posts.isEmpty {
                    // Never a silently blank list: a failed first load
                    // (very possible on the watch — wrist-down cancels the
                    // in-flight request with the scene) gets a retry.
                    emptyState(viewModel)
                } else {
                    timelineList(viewModel)
                }
            } else {
                ProgressView()
            }
        }
        // Keyed on the session DID (runs again when the session identity
        // lands after the first attempt) AND re-run on every
        // re-appearance, so a load that died with a deactivated scene is
        // retried the next time the wrist comes up.
        .task(id: service.currentUserDID) {
            if viewModel == nil {
                viewModel = TimelineViewModel(service: service)
            }
            if let vm = viewModel, vm.posts.isEmpty {
                await vm.loadInitial()
            }
        }
    }

    private func emptyState(_ viewModel: TimelineViewModel) -> some View {
        VStack(spacing: 8) {
            Text(viewModel.error == nil ? "No posts yet" : "Couldn't load timeline")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                Task { await viewModel.loadInitial() }
            }
            .buttonStyle(.bordered)
        }
    }

    private func timelineList(_ viewModel: TimelineViewModel) -> some View {
        List {
            ForEach(viewModel.posts) { post in
                NavigationLink(value: post.uri) {
                    WatchPostRow(post: post)
                }
            }

            // Tail row: infinite-scroll trigger, or a manual Load More
            // button when the shared feed preference turns paging off.
            if !viewModel.posts.isEmpty {
                if FeedPreferences.infiniteScrollEnabled {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .task { await viewModel.loadMore() }
                } else if viewModel.canLoadMore {
                    Button("Load More") {
                        Task { await viewModel.loadMore() }
                    }
                }
            }
        }
        .navigationDestination(for: String.self) { uri in
            if let post = viewModel.posts.first(where: { $0.uri == uri }) {
                WatchPostDetailView(post: post, viewModel: viewModel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}

// MARK: - Row
struct WatchPostRow: View {
    let post: PostItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(post.authorDisplayName ?? post.authorHandle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(post.createdAt.atmoFormatted())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Reply context — the parent ships in the timeline payload.
            if let parent = post.threadAncestors.last {
                Label("@\(parent.authorHandle)", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(post.displayText)
                .font(.caption)
                .lineLimit(4)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail
struct WatchPostDetailView: View {
    let post: PostItem
    let viewModel: TimelineViewModel

    /// Live copy from the view model so like/repost state stays current.
    private var currentPost: PostItem {
        viewModel.posts.first(where: { $0.id == post.id }) ?? post
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentPost.authorDisplayName ?? currentPost.authorHandle)
                    .font(.footnote.weight(.semibold))
                Text("@\(currentPost.authorHandle)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(currentPost.displayText)
                    .font(.body)

                HStack(spacing: 12) {
                    Button {
                        Task { await viewModel.toggleLike(post: currentPost) }
                    } label: {
                        Label("\(currentPost.likeCount)", systemImage: currentPost.isLiked ? "heart.fill" : "heart")
                    }
                    .tint(currentPost.isLiked ? .red : nil)

                    Button {
                        Task { await viewModel.toggleRepost(post: currentPost) }
                    } label: {
                        Label("\(currentPost.repostCount)", systemImage: "arrow.2.squarepath")
                    }
                    .tint(currentPost.isReposted ? .green : nil)
                }
                .labelStyle(.titleAndIcon)
                .font(.caption)
            }
        }
        .navigationTitle("Post")
    }
}
