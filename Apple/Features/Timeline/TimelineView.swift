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

    /// Non-observed scroll bookkeeping (previous offset, velocity). Lives in
    /// a reference box so the per-frame samples during scrolling never
    /// invalidate the view tree — only the deliberate flips below (isAtTop,
    /// pullDistance) trigger renders. Writing a plain @State CGFloat here
    /// re-evaluated the whole feed body every scroll tick, costing frames.
    @State private var scrollMetrics = ScrollMetrics()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The row the viewport is anchored to (topmost visible post URI).
    /// Bound to `.scrollPosition(id:)`, which keeps that row in place when
    /// rows are inserted above it — the mechanism that stops the feed from
    /// jumping when the background check prepends new posts.
    @State private var scrolledID: String? = nil

    /// Debounces iCloud read-position writes while the user scrolls.
    @State private var positionSaveTask: Task<Void, Never>? = nil

    /// Where the user was before the last jump-to-top — the Home button's
    /// down-arrow state jumps back here.
    @State private var returnAnchorURI: String? = nil

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
        ScrollViewReader { proxy in
        ZStack(alignment: .top) {
            ScrollView {
                // Top anchor for programmatic scroll-to-top. proxy.scrollTo
                // is used for jumps because writes to the scrollPosition
                // binding are unreliable as a scroll trigger (they race the
                // binding's own continuous updates).
                Color.clear
                    .frame(height: 0)
                    .id("__top__")

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
                        // Subtle fade as rows materialize mid-scroll; skipped
                        // while the feed is flying by (the eye can't track it
                        // and the frames are needed for scrolling) and under
                        // Reduce Motion. Each row fades at most once.
                        .modifier(RowFadeIn(shouldAnimate: {
                            !reduceMotion && scrollMetrics.velocity < 3000
                        }))
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
            // A separate child view so ONLY it re-evaluates as the unseen
            // set drains (markNewPostSeen fires for every row scrolled
            // past) — reading newPostsCount here made the entire feed body
            // re-diff per row during the drain.
            NewPostsPillOverlay(vm: vm) {
                jumpToTop(vm: vm, proxy: proxy)
            }
            .zIndex(10)

            // ── Scroll-to-top FAB (iPad/macOS only) ──
            // On the iPhone this control lives in the bottom bar instead —
            // as a floating overlay its taps kept falling through to the
            // feed rows and opening threads.
            if !isAtTop, showsFloatingScrollToTop {
                ScrollToTopButton {
                    jumpToTop(vm: vm, proxy: proxy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, scrollToTopTrailingPadding)
                .padding(.bottom, scrollToTopBottomPadding)
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
#if os(iOS)
        // The Home button signals through the shared chrome state; each
        // bump is one jump request (up to the top, or back down to where
        // the user left from).
        .onChange(of: PhoneChromeState.shared.scrollToTopRequest) { _, _ in
            jumpToTop(vm: vm, proxy: proxy)
        }
        .onChange(of: PhoneChromeState.shared.scrollBackRequest) { _, _ in
            jumpBack(vm: vm, proxy: proxy)
        }
#endif
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
    }

    /// The floating overlay button renders on iPad/macOS only — the iPhone
    /// hosts this control in its bottom bar instead.
    private var showsFloatingScrollToTop: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
#else
        true
#endif
    }

    /// Horizontal position: center the 44pt button over the floating
    /// compose FAB (56pt wide at its xxl inset).
    private var scrollToTopTrailingPadding: CGFloat {
        AtmoTheme.Spacing.xxl + 6
    }

    /// Vertical position: clear the compose FAB below (56pt + its inset).
    private var scrollToTopBottomPadding: CGFloat {
        AtmoTheme.Spacing.xxl + 56 + AtmoTheme.Spacing.md
    }

    /// Scrolls to the newest post and retires the pill. Shared by the pill
    /// tap and the scroll-to-top FAB (a fast programmatic scroll can skip
    /// row onAppear callbacks, so the unseen set is cleared explicitly).
    ///
    /// Nearby, the scroll glides; from deep in the feed it snaps instead —
    /// animating across dozens of lazy rows forces every one of them to lay
    /// out mid-flight, which is exactly the stutter it would be trying to
    /// look smooth through.
    private func jumpToTop(vm: TimelineViewModel, proxy: ScrollViewProxy) {
        vm.clearNewPostsCount()
        // Remember where the user left from, so the Home button's
        // down-arrow state can bring them straight back.
        if !isAtTop, let current = scrolledID {
            returnAnchorURI = current
#if os(iOS)
            PhoneChromeState.shared.timelineReturnAvailable = true
#endif
        }
        let currentIndex = scrolledID
            .flatMap { id in vm.posts.firstIndex(where: { $0.uri == id }) } ?? 0
        if reduceMotion || currentIndex > 25 {
            proxy.scrollTo("__top__", anchor: .top)
        } else {
            withAnimation(.smooth(duration: 0.35)) {
                proxy.scrollTo("__top__", anchor: .top)
            }
        }
        if let first = vm.posts.first {
            positionStore.save(topPostURI: first.uri)
        }
    }

    /// Jumps back to the stored pre-jump position (Home's down-arrow).
    private func jumpBack(vm: TimelineViewModel, proxy: ScrollViewProxy) {
        defer {
            returnAnchorURI = nil
#if os(iOS)
            PhoneChromeState.shared.timelineReturnAvailable = false
#endif
        }
        guard let anchor = returnAnchorURI,
              let index = vm.posts.firstIndex(where: { $0.uri == anchor })
        else { return }
        if reduceMotion || index > 25 {
            proxy.scrollTo(anchor, anchor: .top)
        } else {
            withAnimation(.smooth(duration: 0.35)) {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    // MARK: - Scroll offset handler
    private func handleScrollOffset(
        _ offset: CGFloat,
        vm: TimelineViewModel
    ) {
        let previous = scrollMetrics.previousOffset
        scrollMetrics.sample(offset: offset)

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

#if os(iOS)
        // Native-style bar minimize on the phone: scrolling down collapses
        // the bottom bar to a corner button; scrolling up (or returning to
        // the top) restores it. Writes are guarded so per-frame samples
        // don't churn the observable.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let chrome = PhoneChromeState.shared
            if chrome.timelineAtTop != nowAtTop {
                chrome.timelineAtTop = nowAtTop
            }
            let delta = offset - previous
            if nowAtTop || delta > 8 {
                if chrome.barCollapsed { chrome.barCollapsed = false }
            } else if offset < -120, delta < -4, !chrome.barCollapsed {
                chrome.barCollapsed = true
            }
        }
#endif

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
                // Rough-surface ratchet: a faint tick every ~9pt of travel,
                // growing firmer as the pull approaches the trigger point.
                if abs(offset - scrollMetrics.lastPullTickOffset) >= 9 {
                    scrollMetrics.lastPullTickOffset = offset
                    Haptics.pullTick(progress: min(1, offset / refreshThreshold))
                }
            } else if pullDistance > 0 {
                scrollMetrics.lastPullTickOffset = 0
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
            // Confirming tap: the release engaged the refresh.
            Haptics.confirm()
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

// MARK: - Scroll Metrics
/// Reference box for per-frame scroll bookkeeping. Mutations here don't
/// invalidate any view — @State only guarantees the instance's identity.
@MainActor
final class ScrollMetrics {
    private(set) var previousOffset: CGFloat = 0
    private var lastSampleTime: TimeInterval = 0
    /// Smoothed vertical scroll speed in points/second. Drives the
    /// "don't bother animating during a fling" gate.
    private(set) var velocity: CGFloat = 0

    /// Offset at which the last pull-to-refresh haptic tick fired — the
    /// ratchet emits one tick per step of travel, not per frame.
    var lastPullTickOffset: CGFloat = 0

    func sample(offset: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastSampleTime
        if dt > 0, dt < 0.5 {
            let instantaneous = abs(offset - previousOffset) / dt
            // Light exponential smoothing so one long frame doesn't spike it.
            velocity = velocity * 0.7 + instantaneous * 0.3
        } else {
            // Stale sample (first event, or the scroller idled): reset.
            velocity = 0
        }
        lastSampleTime = now
        previousOffset = offset
    }
}

// MARK: - Row Fade-In
/// A quick, subtle fade for rows materializing into the viewport. The gate
/// closure runs at appear time; returning false (fast fling, Reduce Motion)
/// shows the row instantly. State persists per row identity, so a row fades
/// at most once — scrolling back over it never re-animates.
private struct RowFadeIn: ViewModifier {
    let shouldAnimate: () -> Bool
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .onAppear {
                guard !visible else { return }
                if shouldAnimate() {
                    withAnimation(.easeOut(duration: 0.18)) { visible = true }
                } else {
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { visible = true }
                }
            }
    }
}

// MARK: - Refresh Indicator
// The pull dial: ratchet detents appear one by one around the ring as the
// pull deepens — the visual counterpart of the rough-surface haptic — while
// a gradient arc fills toward the trigger point. Crossing the threshold
// flips the arrow and pops the dial ("release to refresh"); releasing swaps
// it for the spinner with a scale pop.
private struct RefreshIndicatorView: View {
    let pullDistance: CGFloat
    let threshold: CGFloat
    let isRefreshing: Bool

    // Progress: 0 = just started pulling, 1 = at/past threshold
    private var progress: CGFloat {
        min(1, pullDistance / threshold)
    }

    /// Releasing now would refresh.
    private var ready: Bool { progress >= 1 }

    var body: some View {
        VStack {
            Spacer()
            ZStack {
                if isRefreshing {
                    // Spinning indefinitely while fetch is in progress
                    ProgressView()
                        .tint(AtmoColors.accent)
                        .scaleEffect(0.9)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    // Ratchet detents — one per haptic step of the pull.
                    ForEach(0..<8, id: \.self) { index in
                        Capsule()
                            .fill(AtmoColors.accent)
                            .frame(width: 2, height: 5)
                            .offset(y: -14)
                            .rotationEffect(.degrees(Double(index) * 45))
                            .opacity(min(1, max(0, progress * 9 - CGFloat(index))) * 0.5)
                    }

                    // Gradient arc filling toward the trigger point, with a
                    // slight wind-up rotation for liveliness.
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AngularGradient(
                                colors: [AtmoColors.accent.opacity(0.25), AtmoColors.accent],
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(360 * progress)
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .frame(width: 20, height: 20)
                        .rotationEffect(.degrees(-90))
                        .rotationEffect(.degrees(progress * 120))

                    // Arrow flips upward the moment releasing would refresh.
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AtmoColors.accent)
                        .opacity(min(1, progress * 1.8))
                        .rotationEffect(.degrees(ready ? 180 : 0))
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: ready)
                }
            }
            .frame(width: 36, height: 36)
            .glassEffect(.regular, in: Circle())
            // Grows with the pull; pops slightly at the ready point.
            .scaleEffect((0.6 + 0.4 * progress) * (ready ? 1.12 : 1.0))
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: ready)
            .opacity(progress)
            Spacer()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRefreshing)
    }
}

// MARK: - New Posts Pill Overlay
// Isolation boundary for the pill's observable reads: the unseen-post set
// mutates on every row the user scrolls past while draining, and only this
// small view should pay for those invalidations — not the feed body.
private struct NewPostsPillOverlay: View {
    let vm: TimelineViewModel
    let onJump: () -> Void

    var body: some View {
        VStack {
            if vm.newPostsCount > 0 {
                NewPostsPill(
                    count: vm.newPostsCount,
                    authors: vm.newPostAuthors,
                    overflowAuthorCount: vm.newPostsOverflowAuthorCount
                ) {
                    onJump()
                }
                .padding(.top, AtmoTheme.Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: vm.newPostsCount)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.newPostsCount > 0)
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
