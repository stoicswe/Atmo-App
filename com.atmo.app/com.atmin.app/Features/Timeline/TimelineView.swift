import SwiftUI

// Navigation value for opening a thread
struct PostNavTarget: Hashable {
    let uri: String
}

// MARK: - TimelineView
struct TimelineView: View {
    @Bindable var viewModel: TimelineViewModel
    @Environment(ATProtoService.self) private var service

    /// When non-nil (iPad/macOS split view), navigation is handled by the parent
    /// NavigationStack in AppNavigation and this view renders as flat content.
    /// When nil (iPhone), this view owns its own NavigationStack.
    var splitNavPath: Binding<NavigationPath>? = nil

    @State private var ownedNavPath = NavigationPath()

    // Scroll detection
    @State private var isAtTop: Bool = true
    @State private var scrollOffset: CGFloat = 0

    // New posts pill
    @State private var showNewPostsPill: Bool = false

    // Custom pull-to-refresh state
    @State private var isRefreshTriggered: Bool = false
    @State private var pullDistance: CGFloat = 0
    private let refreshThreshold: CGFloat = 64

    // iCloud position store
    private let positionStore = PositionStore.shared
    @State private var positionSaveTask: Task<Void, Never>? = nil

    /// The active nav path binding — external (split view) or internal (iPhone).
    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    var body: some View {
        // On iPhone we own the NavigationStack. On iPad/macOS the parent stack
        // (AppNavigation.splitNavPath) handles all navigation — we are flat content.
        if splitNavPath != nil {
            feedBody
                .task { await loadIfNeeded() }
                .onChange(of: service.atProtoKit != nil) { _, isReady in
                    guard isReady, viewModel.posts.isEmpty, !viewModel.isLoading else { return }
                    Task { await viewModel.loadInitial() }
                }
        } else {
            NavigationStack(path: $ownedNavPath) {
                feedBody
                    .navigationTitle("Home")
#if os(iOS)
                    .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
#endif
                    .navigationDestination(for: PostNavTarget.self) { target in
                        ThreadView(postURI: target.uri)
                    }
                    .navigationDestination(for: String.self) { did in
                        ProfileView(actorDID: did)
                    }
            }
            .task { await loadIfNeeded() }
            .onChange(of: service.atProtoKit != nil) { _, isReady in
                guard isReady, viewModel.posts.isEmpty, !viewModel.isLoading else { return }
                Task { await viewModel.loadInitial() }
            }
        }
    }

    private func loadIfNeeded() async {
        // AppNavigation kicks off loadInitial() when it creates the VM, so by the time
        // TimelineView appears the fetch may already be in flight or finished.
        // Only load here if neither condition is true (e.g. iPhone tab view).
        guard viewModel.posts.isEmpty, !viewModel.isLoading else { return }
        await viewModel.loadInitial()
    }

    // MARK: - Feed Body (flat — no NavigationStack)
    @ViewBuilder
    private var feedBody: some View {
        if viewModel.isLoading && viewModel.posts.isEmpty {
            LoadingView(message: "Loading timeline…")
        } else {
            feedContent(vm: viewModel)
        }
    }

    @ViewBuilder
    private func feedContent(vm: TimelineViewModel) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    // ── Custom pull-to-refresh spring indicator ──
                    // This GeometryReader sits at y=0 in the scroll content.
                    // When the user pulls down past refreshThreshold it triggers a refresh,
                    // and springs the content back with a satisfying bounce.
                    GeometryReader { geo in
                        let minY = geo.frame(in: .named("scrollCoord")).minY
                        Color.clear
                            .preference(key: ScrollOffsetKey.self, value: minY)
                    }
                    .frame(height: 0)

                    // Spring refresh indicator — always in the view hierarchy so its
                    // insertion/removal never causes a content-height change that would
                    // snap the scroll position. Height is 0 when inactive (invisible),
                    // grows as the user pulls down. The .animation modifier on height
                    // is suppressed while actively refreshing so the indicator stays
                    // pinned open at a fixed height until the fetch completes.
                    RefreshIndicatorView(
                        pullDistance: pullDistance,
                        threshold: refreshThreshold,
                        isRefreshing: viewModel.isRefreshing
                    )
                    .frame(height: max(0, pullDistance))
                    .animation(
                        viewModel.isRefreshing
                            ? nil  // don't animate while refreshing (held open)
                            : .spring(response: 0.35, dampingFraction: 0.65),
                        value: pullDistance
                    )
                    .clipped()

                    // ── Top anchor for at-top detection ──
                    Color.clear
                        .frame(height: 0)
                        .id("__top__")
                        .onAppear {
                            Task { @MainActor in isAtTop = true }
                        }
                        .onDisappear {
                            Task { @MainActor in isAtTop = false }
                        }

                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(vm.posts) { post in
                            FeedItemView(
                                post: post,
                                viewModel: vm,
                                onTap: {
                                    // Reset the path to a single item so Back always
                                    // returns directly to the timeline, regardless of
                                    // any previously visited threads.
                                    navPath.wrappedValue = NavigationPath([PostNavTarget(uri: post.uri)])
                                },
                                onMentionTap: { handle in
                                    // Profile pushes also reset — tapping a mention from
                                    // the feed shouldn't carry stale thread history.
                                    navPath.wrappedValue = NavigationPath([handle])
                                }
                            )
                            .onAppear {
                                if post.id == vm.posts.last?.id {
                                    Task { await vm.loadMore() }
                                }
                            }
                            .id(post.uri)

                            Divider().overlay(Color.secondary.opacity(0.1))
                        }

                        if vm.isLoading && !vm.posts.isEmpty {
                            ProgressView()
                                .padding(AtmoTheme.Spacing.xxl)
                        }
                    }
                }
                // Coordinate space so GeometryReader can measure scroll offset
                .coordinateSpace(name: "scrollCoord")
                // Read scroll offset from preference key
                .onPreferenceChange(ScrollOffsetKey.self) { value in
                    handleScrollOffset(value, vm: vm, proxy: proxy)
                }
                .overlay {
                    if let error = vm.error {
                        ErrorBannerView(message: error.localizedDescription) {
                            Task { await vm.refresh() }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }

                // ── New Posts Pill ──
                if showNewPostsPill && vm.newPostsCount > 0 {
                    NewPostsPill(count: vm.newPostsCount, authors: vm.newPostAuthors) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                            showNewPostsPill = false
                        }
                        vm.clearNewPostsCount()
                        proxy.scrollTo("__top__", anchor: .top)
                        if let first = vm.posts.first {
                            positionStore.save(topPostURI: first.uri)
                        }
                    }
                    .padding(.top, AtmoTheme.Spacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: showNewPostsPill)
                }

                // Invisible change-watcher — not rendered, just reacts to ViewModel state.
                // When the background refresh or periodic timer prepends new posts,
                // newPostsCount goes from 0 → N. We show the pill immediately regardless
                // of the current scroll position, and re-anchor the scroll so the existing
                // content doesn't visually jump upward as new rows are inserted above it.
                Color.clear
                    .frame(width: 0, height: 0)
                    .onChange(of: vm.newPostsCount) { oldCount, newCount in
                        guard newCount > 0, oldCount == 0 else { return }
                        // Re-anchor scroll FIRST (no animation) so the viewport stays
                        // glued to the same post even though new rows were inserted above.
                        if let anchor = vm.newPostsAnchorURI {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                        // If the user is already at the top, silently absorb and clear —
                        // the new posts are already visible, no pill needed.
                        if isAtTop {
                            vm.clearNewPostsCount()
                            if let first = vm.posts.first {
                                positionStore.save(topPostURI: first.uri)
                            }
                            return
                        }
                        // User is scrolled down: show the pill so they can tap to jump up.
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            showNewPostsPill = true
                        }
                    }

                // ── Scroll-to-top FAB ──
                // Appears in the bottom-trailing corner once the user has scrolled
                // away from the top. Tapping scrolls smoothly back to the first post.
                if !isAtTop {
                    ScrollToTopButton {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                            proxy.scrollTo("__top__", anchor: .top)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, AtmoTheme.Spacing.xxl)
                    .padding(.bottom, AtmoTheme.Spacing.xxl)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .zIndex(9)
                    .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isAtTop)
                }
            }
        }
    }

    // MARK: - Scroll offset handler
    private func handleScrollOffset(
        _ offset: CGFloat,
        vm: TimelineViewModel,
        proxy: ScrollViewProxy
    ) {
        let previous = scrollOffset
        scrollOffset = offset

        // ── Pull-to-refresh ──
        // offset > 0 means the user has actively pulled the scroll content below its
        // natural top edge. We only update pullDistance when the user is ACTIVELY
        // pulling (offset > 0). During normal downward scrolling (offset <= 0) we
        // never set pullDistance because doing so calls withAnimation on every scroll
        // tick, which interrupts the momentum scroller and causes the visible jump.
        if !isRefreshTriggered && !viewModel.isRefreshing {
            if offset > 0 {
                // Active pull: apply rubber-band damping so it feels resistive
                let damped = offset < refreshThreshold
                    ? offset
                    : refreshThreshold + (offset - refreshThreshold) * 0.3
                // Direct assignment — no animation — keeps the indicator glued to the finger
                pullDistance = damped
            } else if pullDistance > 0 {
                // Finger released back to natural position: animate the snap closed.
                // This branch only fires ONCE per pull-release (when pullDistance transitions
                // from > 0 back to 0), not on every normal scroll tick.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    pullDistance = 0
                }
            }
        }

        // Detect pull-and-release: offset was above threshold then snapped to ≤ 0
        if !isRefreshTriggered && !viewModel.isRefreshing && previous > refreshThreshold && offset <= 0 {
            isRefreshTriggered = true
            Task {
                // Hold the indicator open at ~75% threshold height while fetching
                withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                    pullDistance = refreshThreshold * 0.75
                }
                showNewPostsPill = false
                vm.clearNewPostsCount()
                await vm.refresh()
                // Spring back closed once fetch completes
                withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                    pullDistance = 0
                }
                isRefreshTriggered = false
            }
        }

        // ── Debounce position save ──
        positionSaveTask?.cancel()
        positionSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            // The first post visible is roughly our scroll position — saved via positionStore
        }
    }
}

// MARK: - Scroll Offset Preference Key
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Refresh Indicator
// A spring-animated spinner that appears when the user pulls down.
// Grows from nothing as pull distance increases, spins when refreshing.
private struct RefreshIndicatorView: View {
    let pullDistance: CGFloat
    let threshold: CGFloat
    let isRefreshing: Bool

    // Progress: 0 = just started pulling, 1 = at/past threshold
    private var progress: CGFloat {
        min(1, pullDistance / threshold)
    }

    var body: some View {
        VStack {
            Spacer()
            ZStack {
                if isRefreshing {
                    // Spinning indefinitely while fetch is in progress
                    ProgressView()
                        .tint(AtmoColors.skyBlue)
                        .scaleEffect(0.9)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    // Circular progress arc tracking pull distance
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AtmoColors.skyBlue.opacity(0.25 + 0.75 * progress),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .frame(width: 22, height: 22)
                        .rotationEffect(.degrees(-90))
                        // Rotate the arc as you pull — adds liveliness
                        .rotationEffect(.degrees(progress * 180))
                        .scaleEffect(0.5 + 0.5 * progress)

                    // Checkmark-like arrow that appears near threshold
                    if progress > 0.7 {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AtmoColors.skyBlue)
                            .opacity((progress - 0.7) / 0.3)
                            .rotationEffect(.degrees(progress >= 1 ? 180 : 0))
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: progress >= 1)
                    }
                }
            }
            .frame(width: 32, height: 32)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            }
            .opacity(progress)
            .scaleEffect(0.7 + 0.3 * progress)
            Spacer()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRefreshing)
    }
}

// MARK: - New Posts Pill
// Shows up to 4 stacked author avatars, an overflow badge when there are more
// unseen authors, and a label with the new-post count.
//
// Layout:  [avatar][avatar][avatar][+N]  ↑ N new posts
//
// • Each avatar is 28 pt, overlapping by 8 pt so the stack stays compact.
// • Overflow badge ("+" + remaining unique-author count) appears after the
//   4th avatar only when more than 4 distinct authors posted.
// • When only 1 author posted the label reads "1 new post".
// • The whole pill is a tappable Button that scrolls to the top and dismisses.
private struct NewPostsPill: View {
    let count: Int
    /// Up to 4 unique-author PostItems, newest-first (from TimelineViewModel).
    let authors: [PostItem]
    let action: () -> Void

    // Size constants
    private let avatarSize: CGFloat = 28
    private let overlap:    CGFloat = 8

    var body: some View {
        Button(action: action) {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                // ── Avatar stack ──
                if !authors.isEmpty {
                    avatarStack
                }

                // ── Up arrow + count label ──
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.caption.weight(.bold))
                    Text(count == 1 ? "1 new post" : "\(count) new posts")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
            }
            .padding(.leading, authors.isEmpty ? AtmoTheme.Spacing.md : AtmoTheme.Spacing.sm)
            .padding(.trailing, AtmoTheme.Spacing.md)
            .padding(.vertical, AtmoTheme.Spacing.sm)
            .background {
                Capsule()
                    .fill(AtmoColors.skyBlue)
                    .shadow(color: AtmoColors.skyBlue.opacity(0.4), radius: 8, y: 4)
            }
        }
        .buttonStyle(.plain)
    }

    /// Overlapping avatar circles, each offset left by `overlap` pts.
    @ViewBuilder
    private var avatarStack: some View {
        // ZStack with negative spacing produces the overlapping fan effect.
        // We render in reverse order so the first (newest) author sits on top.
        let displayed = authors // already capped at 4 in the ViewModel
        ZStack(alignment: .leading) {
            ForEach(Array(displayed.enumerated()), id: \.element.authorDID) { index, author in
                AvatarView(url: author.authorAvatarURL, size: avatarSize)
                    .overlay(
                        Circle()
                            .strokeBorder(AtmoColors.skyBlue, lineWidth: 1.5)
                    )
                    .offset(x: CGFloat(index) * (avatarSize - overlap))
                    .zIndex(Double(displayed.count - index)) // first author on top
            }
        }
        // Total width = size + (n-1) * (size - overlap)
        .frame(
            width: avatarSize + CGFloat(max(0, displayed.count - 1)) * (avatarSize - overlap),
            height: avatarSize
        )
    }
}

// MARK: - Scroll To Top Button
// A Liquid Glass FAB that appears after scrolling down and snaps the feed
// back to the top when tapped. Shared between TimelineView and ThreadView.
struct ScrollToTopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AtmoColors.skyBlue)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
        }
        .buttonStyle(ScrollToTopButtonStyle())
        .atmoShadow(AtmoTheme.Shadow.floating)
    }
}

private struct ScrollToTopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Skeleton Loading View
private struct PostSkeletonView: View {
    @State private var phase: CGFloat = -1.0

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            Circle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: AtmoTheme.Feed.avatarSize, height: AtmoTheme.Feed.avatarSize)
                .shimmer(phase: phase)

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 140, height: 12)
                    .shimmer(phase: phase)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
                    .shimmer(phase: phase)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 200, height: 12)
                    .shimmer(phase: phase)
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Feed.verticalPadding)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = 1.0
            }
        }
    }
}

private extension View {
    func shimmer(phase: CGFloat) -> some View {
        self.overlay(
            LinearGradient(
                colors: [.clear, .white.opacity(0.15), .clear],
                startPoint: UnitPoint(x: phase - 0.5, y: 0),
                endPoint: UnitPoint(x: phase + 0.5, y: 0)
            )
        )
    }
}
