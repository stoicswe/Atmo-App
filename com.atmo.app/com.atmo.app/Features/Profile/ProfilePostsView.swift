import SwiftUI

struct ProfilePostsView: View {
    let posts: [PostItem]
    let isLoading: Bool
    let onLoadMore: () -> Void
    @State private var stubViewModel: TimelineViewModel?
    @Environment(ATProtoService.self) private var service

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(posts) { post in
                if let vm = stubViewModel {
                    FeedItemView(post: post, viewModel: vm)
                    Divider().overlay(Color.secondary.opacity(0.1))
                        .onAppear {
                            if post.id == posts.last?.id {
                                onLoadMore()
                            }
                        }
                }
            }

            if isLoading {
                ProgressView()
                    .padding(AtmoTheme.Spacing.xxl)
            }
        }
        .task {
            if stubViewModel == nil {
                stubViewModel = TimelineViewModel(service: service)
            }
        }
    }
}
