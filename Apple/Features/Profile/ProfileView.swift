import SwiftUI
import AtmoCore

struct ProfileView: View {
    let actorDID: String?
    @Environment(ATProtoService.self) private var service
    @State private var viewModel: ProfileViewModel?
    /// Passed in by AppNavigation on iPad/macOS so tapping posts navigates
    /// via the shared NavigationStack instead of a local one.
    var splitNavPath: Binding<NavigationPath>? = nil
    @State private var ownedNavPath = NavigationPath()
    @State private var stubViewModel: TimelineViewModel?

    var isOwnProfile: Bool {
        actorDID == nil || actorDID == service.currentUserDID
    }

    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    var body: some View {
        let content = profileContent
        if splitNavPath != nil {
            // Split-view path: AppNavigation owns the NavigationStack and sets the
            // title per-tab via its ZStack. ProfileView must NOT apply .navigationTitle
            // here — doing so causes the title to bleed onto other tabs because the
            // view stays alive (opacity-toggled) even when a different tab is active.
            content
        } else {
            NavigationStack(path: $ownedNavPath) {
                content
                    // iPhone: ProfileView owns its NavigationStack and title here.
                    .navigationTitle(viewModel?.profile?.displayName ?? viewModel?.profile?.handle ?? "Profile")
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .navigationDestination(for: PostNavTarget.self) { target in
                        ThreadView(postURI: target.uri)
                    }
                    .navigationDestination(for: String.self) { did in
                        ProfileView(actorDID: did)
                    }
            }
        }
    }

    /// Shown when nothing loaded, nothing is in flight, and no error was
    /// recorded — instead of a blank page.
    private func retryState(vm: ProfileViewModel) -> some View {
        VStack(spacing: AtmoTheme.Spacing.md) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Couldn't load this profile")
                .font(.headline)
            Button("Try Again") {
                Task { await vm.load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(AtmoColors.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    @ViewBuilder
    private var profileContent: some View {
        // Single ScrollView with one flat LazyVStack — avoids nested LazyVStack
        // scroll glitching caused by two LazyVStacks stacked inside one ScrollView.
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                if let vm = viewModel {
                    if let profile = vm.profile {
                        // ── Header ──
                        ProfileHeaderView(
                            profile: profile,
                            isOwnProfile: isOwnProfile,
                            onFollowTap: { Task { await vm.toggleFollow() } },
                            viewModel: isOwnProfile ? vm : nil
                        )

                        Divider().overlay(AtmoColors.glassDivider)

                        // ── Posts inlined directly into the outer LazyVStack ──
                        // (No nested LazyVStack — eliminates the scroll glitch)
                        if let stubVm = stubViewModel {
                            ForEach(vm.posts) { post in
                                FeedItemView(
                                    post: post,
                                    viewModel: stubVm,
                                    onTap: {
                                        navPath.wrappedValue = NavigationPath([PostNavTarget(uri: post.uri)])
                                    },
                                    onMentionTap: { handle in
                                        navPath.wrappedValue = NavigationPath([handle])
                                    }
                                )
                                .onAppear {
                                    if post.id == vm.posts.last?.id {
                                        Task { await vm.loadPosts() }
                                    }
                                }
                                Divider().overlay(Color.secondary.opacity(0.1))
                            }
                        }

                        if vm.isLoadingPosts {
                            ProgressView()
                                .padding(AtmoTheme.Spacing.xxl)
                        }

                    } else if vm.isLoading {
                        LoadingView(message: "Loading profile…")
                    } else if let error = vm.error {
                        ErrorBannerView(message: error.localizedDescription) {
                            Task { await vm.load() }
                        }
                    } else {
                        // Terminal fallback — the profile isn't loaded, nothing
                        // is in flight, and no error was recorded. This state
                        // used to render a blank screen; always offer a retry.
                        retryState(vm: vm)
                    }
                } else {
                    LoadingView(message: "Loading profile…")
                }
            }
        }
        // Keyed on the session DID: runs on first appearance and again when
        // the session identity lands *after* that first attempt (previously
        // the profile silently stayed empty in that order of events).
        .task(id: service.currentUserDID) {
            if viewModel == nil {
                viewModel = ProfileViewModel(service: service, actorDID: actorDID)
            }
            if stubViewModel == nil {
                stubViewModel = TimelineViewModel(service: service)
            }
            if viewModel?.profile == nil {
                await viewModel?.load()
            }
        }
    }
}
