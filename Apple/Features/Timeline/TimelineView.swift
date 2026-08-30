import SwiftUI
import AtmoCore

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

    /// The row the viewport is anchored to (topmost visible post URI).
    /// Bound to `.scrollPosition(id:)`, which keeps that row in place when
    /// rows are inserted above it — the mechanism that stops the feed from
    /// jumping when the background check prepends new posts.
    @State private var scrolledID: String? = nil

    /// Debounces iCloud read-position writes while the user scrolls.
    @State private var positionSaveTask: Task<Void, Never>? = nil

    // Custom pull-to-refresh state
    @State private var isRefreshTriggered: Bool = false
    @State private var pullDistance: CGFloat = 0
    private let refreshThreshold: CGFloat = 64

    // iCloud position store
    private let positionStore = PositionStore.shared
    /// One-shot: restore the iCloud-synced read position after first load.
    @State private var didRestorePosition = false

    /// Settings → Appearance → Feed. On: pages load automatically near the
    /// end. Off: a manual "Load More" control.
    @AppStorage(FeedPreferences.infiniteScrollKey) private var infiniteScrollEnabled = true

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
        ZStack(alignment: .top) {
            ScrollView {
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

                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(vm.posts) { post in
                        // Post + divider share one scroll-target identity so
                        // `.scrollPosition(id:)` anchors to post URIs only.
                        VStack(spacing: 0) {
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

                            Divider().overlay(Color.secondary.opacity(0.1))
                        }
                        .onAppear {
                            // Scrolling up past a freshly-prepended post
                            // drains it from the new-posts pill.
                            vm.markNewPostSeen(uri: post.uri)
                            if infiniteScrollEnabled, post.id == vm.posts.last?.id {
                                Task { await vm.loadMore() }
                            }
                        }
                        .id(post.uri)
                    }

                    if vm.isLoading && !vm.posts.isEmpty {
                        ProgressView()
                            .padding(AtmoTheme.Spacing.xxl)
                    }

                    // Manual paging when infinite scroll is turned off.
                    if !infiniteScrollEnabled, vm.canLoadMore, !vm.isLoading {
                        Button {
                            Task { await vm.loadMore() }
                        } label: {
                            Label("Load More", systemImage: "arrow.down.circle")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.glass)
                        .padding(AtmoTheme.Spacing.lg)
                    }
                }
                .scrollTargetLayout()
            }
            // Viewport anchoring: the binding tracks the topmost visible row
            // and — crucially — keeps that row in place when rows are inserted
            // above it (new-post prepends) instead of letting the content
            // shift underneath the viewport.
            .scrollPosition(id: $scrolledID, anchor: .top)
            // Exact scroll offset from the system: 0 at natural rest under
            // the bar (insets accounted for), positive while pulled past the
            // top, negative once scrolled down. Unlike a GeometryReader in a
            // named space, this can't be skewed by nav-bar insets — which
            // differ per platform and title style.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, overscroll in
                handleScrollOffset(overscroll, vm: vm)
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
            // Anchored top-center over the feed whenever unseen prepended
            // posts exist; drains live as the user scrolls up past them
            // (see markNewPostSeen). The container VStack scopes the
            // show/hide animation to the pill so the feed itself never
            // animates when the pill appears.
            VStack {
                if vm.newPostsCount > 0 {
                    NewPostsPill(
                        count: vm.newPostsCount,
                        authors: vm.newPostAuthors,
                        overflowAuthorCount: vm.newPostsOverflowAuthorCount
                    ) {
                        jumpToTop(vm: vm)
                    }
                    .padding(.top, AtmoTheme.Spacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: vm.newPostsCount)
                }
            }
            .zIndex(10)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.newPostsCount > 0)

            // ── Scroll-to-top FAB ──
            // Appears in the bottom-trailing corner once the user has scrolled
            // away from the top. Tapping scrolls smoothly back to the first post.
            if !isAtTop {
                ScrollToTopButton {
                    jumpToTop(vm: vm)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, AtmoTheme.Spacing.xxl)
                .padding(.bottom, AtmoTheme.Spacing.xxl)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .zIndex(9)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isAtTop)
            }
        }
        // ── iCloud read-position restore ──
        // Once, after the first page arrives: jump (without animation) to the
        // position saved by whichever Apple device the user read the feed on
        // last; with nothing saved, pin the top row so prepend anchoring is
        // armed before the user's first scroll.
        .onAppear { attemptPositionRestore(vm: vm) }
        .onChange(of: vm.posts.isEmpty) { _, empty in
            if !empty { attemptPositionRestore(vm: vm) }
        }
        // ── iCloud read-position save ──
        // The anchored row IS the read position. Debounced so a fling
        // doesn't hit the KV store for every row it passes.
        .onChange(of: scrolledID) { _, newValue in
            guard let uri = newValue else { return }
            positionSaveTask?.cancel()
            positionSaveTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                positionStore.save(topPostURI: uri)
            }
        }
    }

    /// Scrolls to the newest post and retires the pill. Shared by the pill
    /// tap and the scroll-to-top FAB (a fast programmatic scroll can skip
    /// row onAppear callbacks, so the unseen set is cleared explicitly).
    private func jumpToTop(vm: TimelineViewModel) {
        vm.clearNewPostsCount()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            scrolledID = vm.posts.first?.uri
        }
        if let first = vm.posts.first {
            positionStore.save(topPostURI: first.uri)
        }
    }

    // MARK: - Scroll offset handler
    private func handleScrollOffset(
        _ offset: CGFloat,
        vm: TimelineViewModel
    ) {
        let previous = scrollOffset
        scrollOffset = offset

        // ── At-top detection ──
        // Offset semantics (from onScrollGeometryChange): 0 at natural rest,
        // positive while pulled past the top, negative scrolled down. A
        // small tolerance absorbs sub-pixel settling.
        let nowAtTop = offset >= -8
        if nowAtTop != isAtTop {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                isAtTop = nowAtTop
            }
        }

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
                vm.clearNewPostsCount()
                await vm.refresh()
                // Full replace: snap the anchor to the fresh top row so the
                // viewport isn't pinned to wherever the OLD top row landed
                // in the reloaded page.
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { scrolledID = vm.posts.first?.uri }
                // Spring back closed once fetch completes
                withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                    pullDistance = 0
                }
                isRefreshTriggered = false
            }
        }

    }

    /// One-shot scroll to the iCloud-synced read position. Runs after the
    /// first page loads. When the saved post is no longer in the feed (too
    /// old) it falls back to pinning the current top row, so the scroll
    /// anchor is armed even before the user touches the feed.
    private func attemptPositionRestore(vm: TimelineViewModel) {
        guard !didRestorePosition, !vm.posts.isEmpty else { return }
        didRestorePosition = true
        let saved = positionStore.savedTopPostURI
        let target = (saved != nil && vm.posts.contains { $0.uri == saved })
            ? saved
            : vm.posts.first?.uri
        // Next runloop tick so the LazyVStack has laid out its rows.
        DispatchQueue.main.async {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { scrolledID = target }
        }
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
                        .tint(AtmoColors.accent)
                        .scaleEffect(0.9)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    // Circular progress arc tracking pull distance
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AtmoColors.accent.opacity(0.25 + 0.75 * progress),
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
                            .foregroundStyle(AtmoColors.accent)
                            .opacity((progress - 0.7) / 0.3)
                            .rotationEffect(.degrees(progress >= 1 ? 180 : 0))
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: progress >= 1)
                    }
                }
            }
            .frame(width: 32, height: 32)
            .glassEffect(.regular, in: Circle())
            .opacity(progress)
            .scaleEffect(0.7 + 0.3 * progress)
            Spacer()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRefreshing)
    }
}

// MARK: - New Posts Pill
// Liquid Glass pill anchored top-center over the feed. Shows up to 5
// stacked author avatars for the *unseen* new posts, a "+N" badge when
// more than 5 unique accounts posted, and the unseen-post count.
//
// Layout:  [avatar][avatar][avatar][avatar][avatar][+N]  ↑ N new posts
//
// Live-draining: the ViewModel removes posts from the unseen set as the
// user scrolls up past them, so the count ticks down and avatars leave
// the stack once their author's last unseen post has been passed.
private struct NewPostsPill: View {
    let count: Int
    /// Up to 5 unique-author PostItems, newest-first (from TimelineViewModel).
    let authors: [PostItem]
    /// Unique unseen authors beyond the 5 shown — rendered as "+N".
    let overflowAuthorCount: Int
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

                // ── Overflow badge: unique authors beyond the stack ──
                if overflowAuthorCount > 0 {
                    Text("+\(overflowAuthorCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.25)))
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
            // Tinted Liquid Glass — the prominent-action treatment.
            .glassEffect(.regular.tint(AtmoColors.accent).interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Overlapping avatar circles, each offset left by `overlap` pts.
    @ViewBuilder
    private var avatarStack: some View {
        // ZStack with negative spacing produces the overlapping fan effect.
        // We render in reverse order so the first (newest) author sits on top.
        let displayed = authors // already capped at 5 in the ViewModel
        ZStack(alignment: .leading) {
            ForEach(Array(displayed.enumerated()), id: \.element.authorDID) { index, author in
                AvatarView(url: author.authorAvatarURL, size: avatarSize)
                    .overlay(
                        Circle()
                            .strokeBorder(AtmoColors.accent, lineWidth: 1.5)
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
                .foregroundStyle(AtmoColors.accent)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(ScrollToTopButtonStyle())
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
