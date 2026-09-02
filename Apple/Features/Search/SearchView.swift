import SwiftUI
import AtmoCore

// MARK: - SearchView
//
// Accepts a pre-created, persistent SearchViewModel from AppNavigation so that
// search state (query, results) survives sidebar/tab switches just like the timeline.
// The VM's own 5-minute auto-clear fires when the user navigates away long enough.

struct SearchView: View {
    @Bindable var viewModel: SearchViewModel

    /// When non-nil (iPad/macOS split view), navigation uses the shared parent
    /// NavigationStack in AppNavigation. When nil (iPhone), owns its own stack.
    var splitNavPath: Binding<NavigationPath>? = nil
    /// iPhone shell: the bottom bar hosts the search field, so the in-page
    /// one is hidden there (the category chips stay).
    var hidesSearchField: Bool = false
    @State private var ownedNavPath = NavigationPath()
    /// Search field focus, lifted out of SearchBar so the history pills
    /// can follow the keyboard: up while it's up, gone when it's dismissed.
    @FocusState private var searchFocused: Bool
    /// Switches the timeline to a feed picked from the Feeds results.
    @Environment(\.openFeed) private var openFeed
    /// Arriving on the page shows the pills once before the field is ever
    /// focused; the first keyboard dismissal (or a search) ends that.
    @State private var showHistoryOnArrival = false
    /// Measured height of the search bar row, so the floating pills can
    /// hang exactly under it.
    @State private var searchBarHeight: CGFloat = 0

    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    var body: some View {
        if splitNavPath != nil {
            searchContent(vm: viewModel)
        } else {
            NavigationStack(path: $ownedNavPath) {
                searchContent(vm: viewModel)
                    .navigationTitle("Search")
                    .navigationDestination(for: PostNavTarget.self) { target in
                        ThreadView(postURI: target.uri)
                    }
                    .navigationDestination(for: String.self) { did in
                        ProfileView(actorDID: did)
                    }
            }
        }
    }

    // MARK: - Main search content

    @ViewBuilder
    private func searchContent(vm: SearchViewModel) -> some View {
        // resultBody fills all remaining vertical space; the search bar + chips
        // are pinned to the top via safeAreaInset so they're always visible.
        //
        // IMPORTANT: the search bar is wired via a pure string binding here.
        // onQueryChanged is fired through .onChange(of:) on the TextField inside
        // SearchBar — NOT in the binding setter. This means typing never causes
        // a view-tree rebuild that would dismiss the keyboard or reset focus.
        resultBody(vm: vm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    // ── Search bar ── always present; on iPad / macOS the
                    // refresh control (⌘R re-runs the query) shares its row.
                    if !hidesSearchField {
                        HStack(spacing: AtmoTheme.Spacing.sm) {
                            searchBar(vm: vm)
                            if splitNavPath != nil {
                                refreshButton(vm: vm)
                            }
                        }
                        .padding(.horizontal, AtmoTheme.Spacing.md)
                        .padding(.top, AtmoTheme.Spacing.sm)
                        .padding(.bottom, AtmoTheme.Spacing.xs)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { searchBarHeight = $0 }
                    }

                    // ── Category picker ── a small breath above it, from
                    // the search field or from the toolbar.
                    categoryPicker(vm: vm)
                        .padding(.horizontal, AtmoTheme.Spacing.md)
                        .padding(.top, AtmoTheme.Spacing.sm)
                        .padding(.bottom, AtmoTheme.Spacing.sm)

                    // ── Media filter ── only once a search has post results
                    // and Posts is the open category: All / Images / Videos /
                    // GIFs. Anything but All swaps the list for the grid.
                    if vm.selectedCategory == .posts, !vm.postResults.isEmpty,
                       !vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        mediaFilterRow(vm: vm)
                            .padding(.horizontal, AtmoTheme.Spacing.md)
                            .padding(.bottom, AtmoTheme.Spacing.sm)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Divider().overlay(AtmoColors.glassDivider)
                }
                .background(.bar)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.postResults.isEmpty)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.selectedCategory)
                // Recent searches float under the bar, over the chips and
                // whatever content is below — the header itself never
                // grows, so the chips stay put. They sweep out while the
                // field is focused and empty and tuck back otherwise
                // (opt-in, Settings → Search).
                .overlay(alignment: .topLeading) {
                    if !hidesSearchField {
                        SearchHistoryPills(
                            entries: SearchHistoryStore.shared.recent,
                            visible: historyPillsVisible,
                            onSelect: { entry in runHistorySearch(entry, vm: vm) }
                        )
                        .padding(.horizontal, AtmoTheme.Spacing.md)
                        .padding(.top, searchBarHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .zIndex(1)
                    }
                }
            }
            .onAppear {
                vm.onAppear()
                showHistoryOnArrival = true
            }
            .onDisappear {
                vm.onDisappear()
                showHistoryOnArrival = false
            }
            .onChange(of: searchFocused) { was, now in
                // Keyboard dismissed: the arrival showing is over too.
                if was, !now { showHistoryOnArrival = false }
            }
            .onChange(of: vm.query) { _, query in
                if !query.isEmpty { showHistoryOnArrival = false }
            }
            // Touching the results/explore content counts as moving on.
            .simultaneousGesture(TapGesture().onEnded { showHistoryOnArrival = false })
    }

    /// Glass refresh disc at the end of the search row: re-runs the query
    /// (⌘R), spinner while it runs, dormant until there's something typed.
    private func refreshButton(vm: SearchViewModel) -> some View {
        let canRefresh = vm.query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
        return Button {
            Haptics.tap()
            vm.refresh()
        } label: {
            Group {
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(canRefresh ? Color.primary : Color.secondary)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!canRefresh || vm.isLoading)
        .help("Refresh search")
        .accessibilityLabel("Refresh search")
    }

    private func searchBar(vm: SearchViewModel) -> some View {
        SearchBar(
            query: $viewModel.query,
            isFocused: $searchFocused,
            onCommit: { newValue in vm.onQueryChanged(newValue) },
            onSubmit: { SearchHistoryStore.shared.record(vm.query) }
        )
    }

    /// Pills show while the field is focused (or right after arriving on
    /// the page) and nothing has been typed yet — once a query is in, they
    /// get out of the way of the chips and results. Only with history on
    /// and something recorded.
    private var historyPillsVisible: Bool {
        let store = SearchHistoryStore.shared
        return store.isEnabled
            && !store.recent.isEmpty
            && viewModel.query.isEmpty
            && (searchFocused || showHistoryOnArrival)
    }

    private func runHistorySearch(_ entry: String, vm: SearchViewModel) {
        Haptics.tap()
        SearchHistoryStore.shared.record(entry)
        viewModel.query = entry
        vm.onQueryChanged(entry)
        showHistoryOnArrival = false
        searchFocused = false
    }

    // MARK: - Category Picker

    @ViewBuilder
    private func categoryPicker(vm: SearchViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            categoryPickerRow(vm: vm)
        }
    }

    @ViewBuilder
    private func categoryPickerRow(vm: SearchViewModel) -> some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            ForEach(SearchCategory.allCases) { category in
                CategoryChip(
                    category: category,
                    isSelected: vm.selectedCategory == category,
                    countText: countText(for: category, vm: vm)
                ) {
                    // Same tap-and-slide as the Settings/Activity chips.
                    if vm.selectedCategory != category { Haptics.slideSelect() }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        vm.selectedCategory = category
                    }
                }
            }
            Spacer(minLength: 0)

            // ── Top / Latest ranking for post and feed results ──
            if vm.selectedCategory == .posts || vm.selectedCategory == .feeds {
                Menu {
                    ForEach(SearchViewModel.SearchSort.allCases) { option in
                        Button {
                            Haptics.tap()
                            vm.setSort(option)
                        } label: {
                            if vm.sort == option {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption2.weight(.semibold))
                        Text(vm.sort.displayName)
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AtmoTheme.Spacing.md)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    /// "7", "25+", … — the loaded count, with "+" while more pages exist.
    private func countText(for category: SearchCategory, vm: SearchViewModel) -> String? {
        guard !vm.postResults.isEmpty || !vm.peopleResults.isEmpty
                || !vm.hashtagResults.isEmpty || !vm.feedResults.isEmpty
        else { return nil }
        let count: Int
        let hasMore: Bool
        switch category {
        case .posts:
            count = vm.postResults.count
            hasMore = vm.hasMorePosts
        case .people:
            count = vm.peopleResults.count
            hasMore = vm.hasMorePeople
        case .hashtags:
            count = vm.hashtagResults.count
            // Tags derive from post pages — more posts can mean more tags.
            hasMore = vm.hasMorePosts
        case .feeds:
            count = vm.feedResults.count
            hasMore = vm.hasMoreFeeds
        }
        guard count > 0 else { return nil }
        return "\(count)\(hasMore ? "+" : "")"
    }

    // MARK: - Result Body

    @ViewBuilder
    private func resultBody(vm: SearchViewModel) -> some View {
        // The view tree structure never changes based on isLoading — doing so
        // would rebuild the safeAreaInset that holds the search bar, which
        // dismisses the keyboard. Instead, overlay a spinner on top of the
        // existing (possibly stale) results while a new search is in-flight.
        ZStack {
            if vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Explore suggestions (Bluesky's algorithmic surface) when
                // the content controls allow them; otherwise the plain
                // prompt. Managed minors default to the plain prompt.
                if ParentalControlsStore.shared.active.allowsExploreSuggestions {
                    ExploreSectionsView(searchViewModel: vm, navPath: navPath)
                } else {
                    emptyPrompt
                }
            } else {
                switch vm.selectedCategory {
                case .posts:
                    postsResults(vm: vm)
                case .people:
                    peopleResults(vm: vm)
                case .hashtags:
                    hashtagResults(vm: vm)
                case .feeds:
                    feedsResults(vm: vm)
                }
            }

            // Spinner floats above content while loading; the underlying
            // results (or empty state) stay mounted so no view rebuild occurs.
            if vm.isLoading {
                ProgressView()
                    .tint(AtmoColors.accent)
                    .padding(AtmoTheme.Spacing.lg)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Empty prompt (no query entered yet)

    private var emptyPrompt: some View {
        ContentUnavailableView(
            "Search Bluesky",
            systemImage: "magnifyingglass",
            description: Text("Find posts, people, and hashtags.")
        )
    }

    // MARK: - Posts Results

    /// Mail-style chips, like the category row above: the selected filter
    /// expands into a labeled accent capsule, the rest are icon circles.
    private func mediaFilterRow(vm: SearchViewModel) -> some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            ForEach(MediaFilter.allCases) { filter in
                MediaFilterChip(filter: filter, isSelected: vm.mediaFilter == filter) {
                    if vm.mediaFilter != filter { Haptics.slideSelect() }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        vm.mediaFilter = filter
                    }
                    Task { await vm.fillMediaResults() }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Filter posts by media")
    }

    @ViewBuilder
    private func postsResults(vm: SearchViewModel) -> some View {
        if vm.mediaFilter != .all {
            mediaGridResults(vm: vm)
        } else if vm.postResults.isEmpty {
            noResults(icon: "text.bubble", message: "No posts found for \"\(vm.query)\"")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // AI topic summary for tapped topics (Apple
                    // Intelligence, on-device), streaming in as it writes.
                    if let topic = vm.summaryTopic {
                        // summaryPosts: the background-enriched corpus
                        // (topic feed + contextual variants) when it
                        // exists, else the visible results.
                        TopicSummaryCard(topic: topic, posts: vm.summaryPosts)
                    }
                    ForEach(vm.postResults) { post in
                        SearchPostRow(post: post)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                SearchHistoryStore.shared.record(vm.query)
                                navPath.wrappedValue = NavigationPath([PostNavTarget(uri: post.uri)])
                            }
                            // Infinite scroll: any of the last few rows
                            // appearing loads the next page — exact-last
                            // triggers can be starved when a page appended
                            // nothing new.
                            .onAppear {
                                if vm.postResults.suffix(3).contains(where: { $0.id == post.id }) {
                                    Task { await vm.loadMorePosts() }
                                }
                            }
                        Divider().overlay(Color.secondary.opacity(0.1))
                    }
                    if vm.hasMorePosts {
                        ProgressView()
                            .padding(AtmoTheme.Spacing.lg)
                    }
                }
            }
        }
    }

    // MARK: - Media Grid Results

    @ViewBuilder
    private func mediaGridResults(vm: SearchViewModel) -> some View {
        let posts = vm.mediaFilteredPosts
        if posts.isEmpty {
            if vm.hasMorePosts, !vm.postResults.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: vm.mediaFilter) { await vm.fillMediaResults() }
            } else {
                noResults(
                    icon: vm.mediaFilter.icon,
                    message: "No \(vm.mediaFilter.displayName.lowercased()) found for \"\(vm.query)\""
                )
            }
        } else {
            ScrollView {
                SearchMediaGrid(
                    posts: posts,
                    onOpenPost: { post in
                        SearchHistoryStore.shared.record(vm.query)
                        navPath.wrappedValue = NavigationPath([PostNavTarget(uri: post.uri)])
                    },
                    onReachEnd: {
                        Task { await vm.loadMorePosts(); await vm.fillMediaResults() }
                    }
                )
                .padding(.horizontal, AtmoTheme.Spacing.md)
                .padding(.vertical, AtmoTheme.Spacing.md)
                if vm.hasMorePosts {
                    ProgressView()
                        .padding(AtmoTheme.Spacing.lg)
                }
            }
            .task(id: vm.mediaFilter) { await vm.fillMediaResults() }
        }
    }

    // MARK: - People Results

    @ViewBuilder
    private func peopleResults(vm: SearchViewModel) -> some View {
        if vm.peopleResults.isEmpty {
            noResults(icon: "person.2", message: "No accounts found for \"\(vm.query)\"")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.peopleResults) { person in
                        SearchPersonRow(person: person)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                SearchHistoryStore.shared.record(vm.query)
                                navPath.wrappedValue = NavigationPath([person.did])
                            }
                            // Infinite scroll, same as the posts list.
                            .onAppear {
                                if vm.peopleResults.suffix(3).contains(where: { $0.did == person.did }) {
                                    Task { await vm.loadMorePeople() }
                                }
                            }
                        Divider().overlay(Color.secondary.opacity(0.1))
                    }
                    if vm.hasMorePeople {
                        ProgressView()
                            .padding(AtmoTheme.Spacing.lg)
                    }
                }
            }
        }
    }

    // MARK: - Feed Results

    @ViewBuilder
    private func feedsResults(vm: SearchViewModel) -> some View {
        if vm.feedResults.isEmpty {
            noResults(icon: "square.stack", message: "No feeds found for \"\(vm.query)\"")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Shown under the Top/Latest switch; loaded order is
                    // the server's popularity ranking.
                    let feeds = vm.sortedFeedResults
                    ForEach(feeds) { feed in
                        SearchFeedRow(feed: feed)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.tap()
                                SearchHistoryStore.shared.record(vm.query)
                                openFeed(feed.asCustomFeed)
                            }
                            // Infinite scroll, same as the other lists.
                            .onAppear {
                                if feeds.suffix(3).contains(where: { $0.id == feed.id }) {
                                    Task { await vm.loadMoreFeeds() }
                                }
                            }
                        Divider().overlay(Color.secondary.opacity(0.1))
                    }
                    if vm.hasMoreFeeds {
                        ProgressView()
                            .padding(AtmoTheme.Spacing.lg)
                    }
                }
            }
        }
    }

    // MARK: - Hashtag Results

    @ViewBuilder
    private func hashtagResults(vm: SearchViewModel) -> some View {
        if vm.hashtagResults.isEmpty {
            noResults(
                icon: "number",
                message: vm.query.contains("#")
                    ? "No hashtags in your query"
                    : "Type #hashtag to search for tags"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.hashtagResults, id: \.self) { tag in
                        HashtagRow(tag: tag)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Re-run search scoped to this hashtag
                                let newQuery = "#\(tag)"
                                vm.query = newQuery
                                vm.onQueryChanged(newQuery)
                                vm.selectedCategory = .posts
                            }
                            // Tags derive from post pages — reaching the
                            // end pulls the next page to surface more.
                            .onAppear {
                                if tag == vm.hashtagResults.last {
                                    Task { await vm.loadMorePosts() }
                                }
                            }
                        Divider().overlay(Color.secondary.opacity(0.1))
                    }
                    if vm.hasMorePosts {
                        ProgressView()
                            .padding(AtmoTheme.Spacing.lg)
                    }
                }
            }
        }
    }

    // MARK: - No Results placeholder

    private func noResults(icon: String, message: String) -> some View {
        ContentUnavailableView(
            "No Results",
            systemImage: icon,
            description: Text(message)
        )
    }
}

// MARK: - Search Bar
//
// `query` is a pure two-way string binding — no side effects in the setter.
// `onCommit` is called via .onChange(of:) so search triggering is decoupled
// from SwiftUI's binding update cycle and never causes a view-tree rebuild
// that would dismiss the keyboard or reset focus.

private struct SearchBar: View {
    @Binding var query: String
    /// Owned by SearchView so the history pills can track the keyboard.
    var isFocused: FocusState<Bool>.Binding
    /// Called after every debounce-eligible keystroke with the new value.
    var onCommit: ((String) -> Void)? = nil
    /// Return key — the moment a search is deliberately run.
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            TextField("Search Bluesky…", text: $query)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                // Fire the search callback on every change — the ViewModel
                // handles debouncing and minimum-length gating internally.
                .onChange(of: query) { _, newValue in
                    onCommit?(newValue)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    // Notify the VM so it can clear results immediately
                    onCommit?("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, AtmoTheme.Spacing.md)
        .padding(.vertical, AtmoTheme.Spacing.sm)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: query.isEmpty)
    }
}

// MARK: - Search History Pills
// The last few searches as left-aligned glass pills under the search bar
// — the Photos "describe a memory" structure, in the app's own glass.
// Show: each pill starts tucked under the bar and sweeps into place, one
// after another. Hide: they slide back under the bar and fade, in reverse
// order. The container's height follows so the results below make room
// and take it back. Reduce Motion crossfades instead.
struct SearchHistoryPills: View {
    let entries: [String]
    let visible: Bool
    /// Which edge the search bar sits on. `.top`: pills hang below it and
    /// tuck up into it. `.bottom` (iPhone): pills rise above it and tuck
    /// down into it, the most recent search nearest the bar.
    var barEdge: Edge = .top
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Natural height of the pill stack, measured so the collapse animates.
    @State private var stackHeight: CGFloat = 0

    private static let stagger = 0.06
    private static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    /// Pills in display order: nearest the bar first for a top bar; for
    /// a bottom bar the newest sits last, right above the bar.
    private var ordered: [String] {
        barEdge == .bottom ? entries.reversed() : entries
    }

    /// Steps between a pill and the bar (0 = adjacent).
    private func distance(_ index: Int) -> Int {
        barEdge == .bottom ? max(0, ordered.count - 1 - index) : index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {
            ForEach(Array(ordered.enumerated()), id: \.element) { index, entry in
                let steps = CGFloat(distance(index) + 1)
                pill(entry)
                    // Tucked into the bar when hidden: pills further from
                    // it start further away, so the stack emerges from one
                    // point at the bar's edge.
                    .offset(y: visible || reduceMotion ? 0 : (barEdge == .bottom ? steps : -steps) * 28)
                    .scaleEffect(visible || reduceMotion ? 1 : 0.92,
                                 anchor: barEdge == .bottom ? .bottomLeading : .topLeading)
                    .opacity(visible ? 1 : 0)
                    .animation(animation(forDistance: distance(index)), value: visible)
            }
        }
        .padding(.top, AtmoTheme.Spacing.xs)
        .padding(.bottom, AtmoTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Always laid out at its natural height (measured below) so the
        // outer frame can animate between that and zero.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stackHeight = $0 }
        .frame(height: visible ? stackHeight : 0, alignment: barEdge == .bottom ? .bottom : .top)
        .clipped()
        .allowsHitTesting(visible)
        .animation(Self.spring.delay(visible ? 0 : Self.stagger * Double(entries.count)), value: visible)
        .accessibilityHidden(!visible)
    }

    private func animation(forDistance distance: Int) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        // Sweep out from the bar nearest-first; tuck back farthest-first.
        let order = visible ? distance : max(0, entries.count - 1 - distance)
        return Self.spring.delay(Double(order) * Self.stagger)
    }

    private func pill(_ entry: String) -> some View {
        Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contextMenu {
            Button("Remove", systemImage: "xmark", role: .destructive) {
                SearchHistoryStore.shared.remove(entry)
            }
            Button("Clear search history", systemImage: "trash", role: .destructive) {
                SearchHistoryStore.shared.clear()
            }
        }
        .accessibilityLabel("Recent search: \(entry)")
    }
}

// MARK: - Media Filter Chip
// The category chip's smaller sibling for the All / Images / Videos /
// GIFs row: 34 pt icon circles, the selected one expanding into a labeled
// accent capsule.
private struct MediaFilterChip: View {
    let filter: MediaFilter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: filter.icon)
                    .font(.system(size: 13, weight: .medium))
                if isSelected {
                    Text(filter.displayName)
                        .font(.footnote.weight(.semibold))
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, isSelected ? AtmoTheme.Spacing.md : 0)
            .frame(height: 34)
            .frame(minWidth: 34)
            .background {
                Capsule().fill(isSelected ? AtmoColors.accent : Color.secondary.opacity(0.12))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Category Chip

// Mail-style category chip (matches Settings/Activity): a compact icon
// circle that expands into a labeled accent capsule when selected. The
// loaded-result count rides along ("25+" while more pages exist), and
// labels never wrap thanks to fixedSize.
private struct CategoryChip: View {
    let category: SearchCategory
    let isSelected: Bool
    let countText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.system(size: 15, weight: .medium))
                if isSelected {
                    Text(category.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                if let countText {
                    Text(countText)
                        .font(.caption2.weight(.bold))
                        .fixedSize()
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : AtmoColors.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(isSelected
                                      ? Color.white.opacity(0.25)
                                      : AtmoColors.accent.opacity(0.15))
                        }
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, isSelected ? AtmoTheme.Spacing.lg : (countText != nil ? AtmoTheme.Spacing.sm : 0))
            .frame(height: 40)
            .frame(minWidth: 40)
            .background {
                Capsule().fill(isSelected ? AtmoColors.accent : Color.secondary.opacity(0.12))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search Post Row

/// Compact post cell used in search results — no thread context or action row,
/// just enough to identify the post and let the user tap into it.
private struct SearchPostRow: View {
    let post: PostItem

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            AvatarView(url: post.authorAvatarURL, size: AtmoTheme.Feed.avatarSize)

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                // Author line
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    if let name = post.authorDisplayName {
                        Text(name)
                            .font(AtmoFonts.authorName)
                            .lineLimit(1)
                    }
                    if let badge = post.authorVerification {
                        VerifiedBadge(badge: badge)
                    }
                    Text("@\(post.authorHandle)")
                        .font(AtmoFonts.authorHandle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(post.indexedAt.atmoFormatted())
                        .font(AtmoFonts.timestamp)
                        .foregroundStyle(.tertiary)
                }

                // Post text
                if !post.displayText.isEmpty {
                    Text(post.displayText)
                        .font(.subheadline)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                }

                // Media and link embeds render right in the results —
                // photos, videos, link cards, and quotes at a glance. The
                // images load asynchronously (cached), so the result rows
                // land instantly and the media streams in just after.
                if let embed = post.embed {
                    PostEmbedView(embed: embed, sensitiveMedia: post.hasSensitiveMediaLabel)
                }
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Feed.verticalPadding)
    }
}

// MARK: - Search Feed Row
// A public feed found by name: avatar tile, name, who made it and how
// liked it is, then the description. Tapping switches Home to the feed.
private struct SearchFeedRow: View {
    let feed: FeedSearchResult

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Spacing.md) {
            AsyncCachedImage(url: feed.avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AtmoColors.accent.opacity(0.25))
                        .overlay {
                            Image(systemName: "square.stack")
                                .font(.callout)
                                .foregroundStyle(AtmoColors.accent)
                        }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(feed.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(feed.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let description = feed.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this feed")
    }
}

// MARK: - Search Person Row

private struct SearchPersonRow: View {
    let person: ProfileModel

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.md) {
            AvatarView(url: person.avatarURL, size: AtmoTheme.AvatarSize.medium)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let name = person.displayName {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    if let badge = person.verification {
                        VerifiedBadge(badge: badge, size: 12)
                    }
                }
                Text("@\(person.handle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let bio = person.description, !bio.isEmpty {
                    Text(bio)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.sm)
    }
}

// MARK: - Hashtag Row

private struct HashtagRow: View {
    let tag: String

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(AtmoColors.accent.opacity(0.12))
                    .frame(width: 36, height: 36)
                Text("#")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AtmoColors.accent)
            }

            Text("#\(tag)")
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.sm)
    }
}


// MARK: - Explore Sections
// Bluesky's algorithmic Explore surface, shown while the query is empty:
// trending topics, interests, discover feeds, and suggested accounts —
// all straight from Bluesky's suggestion endpoints, labeled as such.
private struct ExploreSectionsView: View {
    let searchViewModel: SearchViewModel
    let navPath: Binding<NavigationPath>

    @Environment(ATProtoService.self) private var service
    @Environment(\.openFeed) private var openFeed

    var body: some View {
        let store = ExploreStore.shared
        ScrollView {
            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.lg) {
                // ── Provenance disclaimer ──
                Label("These are suggested by Bluesky", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !store.trendingTopics.isEmpty {
                    sectionHeader("Trending")
                    ForEach(Array(store.trendingTopics.enumerated()), id: \.element.id) { index, topic in
                        topicRow(rank: index + 1, topic: topic)
                    }
                }

                if !store.suggestedTopics.isEmpty {
                    sectionHeader("Interests")
                    FlowChips(topics: store.suggestedTopics) { topic in
                        Haptics.tap()
                        searchViewModel.activateTopic(
                            topic.topic,
                            description: topic.description,
                            feedURI: topic.feedURI
                        )
                    }
                }

                if !store.suggestedFeeds.isEmpty {
                    sectionHeader("Discover Feeds")
                    ForEach(store.suggestedFeeds) { feed in
                        feedRow(feed)
                    }
                }

                if !store.suggestedAccounts.isEmpty {
                    sectionHeader("Suggested Accounts")
                    ForEach(store.suggestedAccounts) { account in
                        accountRow(account)
                    }
                }

                if !store.hasLoadedOnce {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, AtmoTheme.Spacing.xxl)
                }
            }
            .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
            .padding(.vertical, AtmoTheme.Spacing.md)
        }
        // Keyed on the session DID: runs at first appearance AND again
        // when the session finishes restoring — the personalized sections
        // (feeds, accounts) need it; a launch-time run used to fire before
        // restore and never retry, leaving the page blank.
        .task(id: service.currentUserDID) {
            await ExploreStore.shared.load(service: service)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, AtmoTheme.Spacing.sm)
    }

    private func topicRow(rank: Int, topic: TrendingTopicItem) -> some View {
        Button {
            Haptics.tap()
            // The trend's description and backing feed drive invisible
            // result enrichment for the summary and sparse results.
            searchViewModel.activateTopic(
                topic.topic,
                description: topic.description,
                feedURI: topic.feedURI
            )
        } label: {
            HStack(alignment: .top, spacing: AtmoTheme.Spacing.md) {
                Text("\(rank)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AtmoColors.accent)
                    .frame(width: 22, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(topic.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if topic.isHot {
                            Image(systemName: "flame.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let description = topic.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    // Facepile + post count, like the official Explore.
                    if topic.postCount != nil || !topic.actorAvatarURLs.isEmpty {
                        HStack(spacing: 6) {
                            if !topic.actorAvatarURLs.isEmpty {
                                HStack(spacing: -6) {
                                    ForEach(Array(topic.actorAvatarURLs.enumerated()), id: \.offset) { index, url in
                                        AvatarView(url: url, size: 18)
                                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                                            .zIndex(Double(3 - index))
                                    }
                                }
                            }
                            if let count = topic.postCount {
                                Text("\(count.formatted(.number.notation(.compactName))) posts")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func feedRow(_ feed: CustomFeedItem) -> some View {
        Button {
            Haptics.tap()
            openFeed(feed)
        } label: {
            HStack(spacing: AtmoTheme.Spacing.md) {
                AsyncCachedImage(url: feed.avatarURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AtmoColors.accent.opacity(0.25))
                            .overlay {
                                Image(systemName: "square.stack")
                                    .font(.callout)
                                    .foregroundStyle(AtmoColors.accent)
                            }
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Open this feed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func accountRow(_ account: SuggestedAccountItem) -> some View {
        Button {
            Haptics.tap()
            navPath.wrappedValue.append(account.did)
        } label: {
            HStack(alignment: .top, spacing: AtmoTheme.Spacing.md) {
                AvatarView(url: account.avatarURL, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName ?? account.handle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("@\(account.handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let description = account.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow Chips
// Wrapping capsule chips for the interests list.
private struct FlowChips: View {
    let topics: [TrendingTopicItem]
    let onTap: (TrendingTopicItem) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: AtmoTheme.Spacing.sm)],
            alignment: .leading,
            spacing: AtmoTheme.Spacing.sm
        ) {
            ForEach(topics) { topic in
                Button {
                    onTap(topic)
                } label: {
                    Text(topic.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, AtmoTheme.Spacing.md)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
