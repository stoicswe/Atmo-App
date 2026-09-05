import Adwaita
import Foundation
import AtmoCore

extension MainView {

    struct PersonRowSnapshot: Identifiable, Equatable {
        let id: String
        let name: String
        let handle: String
        let avatarURL: URL?
        let bio: String
        let isFollowing: Bool
    }

    struct FeedRowSnapshot: Identifiable, Equatable {
        let id: String
        let name: String
        let subtitle: String
        let description: String
        let avatarURL: URL?
        let likeCount: Int
        let isSubscribed: Bool
        let isPinned: Bool
    }

    struct SortOption: Identifiable, CustomStringConvertible {
        let id: String
        let description: String
    }

    var sortOptions: [SortOption] {
        SearchViewModel.SearchSort.allCases.map { SortOption(id: $0.rawValue, description: $0.displayName) }
    }

    /// Search categories as AdwToggleGroup items.
    struct CategoryToggle: ToggleGroupItem {
        let id: String
        let icon: Icon?
        var showLabel: Bool { true }
    }

    // MARK: - Model snapshots

    var searchIsLoading: Bool {
        _ = tick
        return onMain { AppSession.shared.search?.isLoading ?? false }
    }

    var searchHasMorePosts: Bool {
        _ = tick
        return onMain { AppSession.shared.search?.hasMorePosts ?? false }
    }

    var searchHasMorePeople: Bool {
        _ = tick
        return onMain { AppSession.shared.search?.hasMorePeople ?? false }
    }

    var searchPostRows: [PostRowSnapshot] {
        _ = tick
        return onMain {
            guard let search = AppSession.shared.search else { return [] }
            let store = AppSession.shared.searchInteractionStore()
            return search.postResults.map { post in
                PostRowSnapshot(post: store?.livePost(uri: post.uri) ?? post)
            }
        }
    }

    var searchPeopleRows: [PersonRowSnapshot] {
        _ = tick
        return onMain {
            (AppSession.shared.search?.peopleResults ?? []).map { profile in
                PersonRowSnapshot(
                    id: profile.did,
                    name: profile.displayName ?? profile.handle,
                    handle: profile.handle,
                    avatarURL: profile.avatarURL,
                    bio: profile.description ?? "",
                    isFollowing: profile.isFollowing
                )
            }
        }
    }

    var searchHashtagRows: [String] {
        _ = tick
        return onMain { AppSession.shared.search?.hashtagResults ?? [] }
    }

    var searchFeedRows: [FeedRowSnapshot] {
        _ = tick
        return onMain {
            (AppSession.shared.search?.sortedFeedResults ?? []).map { feed in
                FeedRowSnapshot(
                    id: feed.uri,
                    name: feed.displayName,
                    subtitle: feed.subtitle,
                    description: feed.description ?? "",
                    avatarURL: feed.avatarURL,
                    likeCount: feed.likeCount,
                    isSubscribed: SavedFeedsStore.shared.isSubscribed(uri: feed.uri),
                    isPinned: SavedFeedsStore.shared.isPinned(uri: feed.uri)
                )
            }
        }
    }

    var searchHistory: [String] {
        _ = tick
        return onMain { SearchHistoryStore.shared.isEnabled ? SearchHistoryStore.shared.recent : [] }
    }

    var searchCategoryToggles: [CategoryToggle] {
        SearchCategory.allCases.map {
            let icon: String
            switch $0 {
            case .posts: icon = "chat-message-new-symbolic"
            case .people: icon = "system-users-symbolic"
            case .hashtags: icon = "atmo-hashtag-symbolic"
            case .feeds: icon = "view-list-symbolic"
            }
            return CategoryToggle(id: $0.rawValue, icon: .custom(name: icon))
        }
    }

    // MARK: - Pane

    @ViewBuilder var searchPane: Body {
        VStack(spacing: 0) {
            SearchEntry()
                .placeholderText("Search posts, people, hashtags, feeds")
                .text($searchQuery)
                .activate { recordSearch() }
                .padding(10)
            if !searchHistory.isEmpty && searchQuery.isEmpty {
                searchHistoryPills
            }
            HStack(spacing: 8) {
                ToggleGroup(selection: $searchCategory, values: searchCategoryToggles)
                    .hexpand()
                if searchCategory == SearchCategory.posts.rawValue {
                    DropDown(selection: sortBinding, values: sortOptions)
                        .tooltip("Sort")
                }
            }
            .padding(8, .horizontal)
            .padding(4, .bottom)
            Separator()
            searchResults
        }
        .onAppear { syncSearchQuery() }
    }

    var sortBinding: Binding<String> {
        Binding(
            get: { searchSort },
            set: { raw in
                searchSort = raw
                guard let sort = SearchViewModel.SearchSort(rawValue: raw) else { return }
                onMain { AppSession.shared.search?.setSort(sort) }
                tick += 1
            }
        )
    }

    /// Recent searches as pills (Settings → Search history); the Apple
    /// app shows the same row above its search bar.
    @ViewBuilder var searchHistoryPills: Body {
        HStack(spacing: 6) {
            ForEach(searchHistory, id: \.self) { entry in
                Button(entry) {
                    searchQuery = entry
                    syncSearchQuery()
                }
                .pill()
                .style("caption")
            }
            Button(icon: .custom(name: "edit-clear-all-symbolic")) {
                onMain { SearchHistoryStore.shared.clear() }
                tick += 1
            }
            .flat()
            .tooltip("Clear search history")
        }
        .halign(.start)
        .padding(10, .horizontal)
        .padding(4, .bottom)
    }

    /// Adwaita re-renders on every keystroke (the SearchEntry binding);
    /// this hands the new text to the shared SearchViewModel exactly once
    /// per change — the debounce, minimum length, and fan-out (posts +
    /// people + hashtags + feeds) all live in core.
    func syncSearchQuery() {
        onMain {
            guard let search = AppSession.shared.search else { return }
            if let category = SearchCategory(rawValue: searchCategory), search.selectedCategory != category {
                search.selectedCategory = category
            }
            guard search.query != searchQuery else { return }
            search.query = searchQuery
            search.onQueryChanged(searchQuery)
        }
    }

    func recordSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        onMain { SearchHistoryStore.shared.record(query) }
        syncSearchQuery()
    }

    @ViewBuilder var searchResults: Body {
        // Keep the view model fed before reading results (body runs on
        // every keystroke; the call is a no-op when the text is unchanged).
        let _ = syncSearchQuery()
        if searchQuery.trimmingCharacters(in: .whitespaces).count < 2 {
            StatusPage(
                "Search Bluesky",
                icon: .custom(name: "system-search-symbolic"),
                description: "Posts, people, hashtags, and feeds."
            )
            .vexpand()
        } else if searchIsLoading && searchPostRows.isEmpty && searchPeopleRows.isEmpty {
            Spinner()
                .vexpand()
                .valign(.center)
        } else {
            switch SearchCategory(rawValue: searchCategory) ?? .posts {
            case .posts: searchPostList
            case .people: searchPeopleList
            case .hashtags: searchHashtagList
            case .feeds: searchFeedList
            }
        }
    }

    @ViewBuilder var searchPostList: Body {
        let rows = searchPostRows
        if rows.isEmpty {
            StatusPage(
                "No posts found",
                icon: .custom(name: "system-search-symbolic"),
                description: "Try different words."
            )
            .vexpand()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.id) { row in
                        postRow(row, actions: .search)
                        Separator()
                    }
                    loadMoreFooter(visible: searchHasMorePosts, loading: searchIsLoading) {
                        loadMoreSearchPosts()
                    }
                }
                .frame(maxWidth: 720)
            }
            .vexpand()
            .onBottomEdgeReached {
                guard infiniteScrollEnabled, searchHasMorePosts else { return }
                loadMoreSearchPosts()
            }
        }
    }

    @ViewBuilder var searchPeopleList: Body {
        let rows = searchPeopleRows
        if rows.isEmpty {
            StatusPage(
                "No people found",
                icon: .custom(name: "system-search-symbolic"),
                description: "Try a handle or a display name."
            )
            .vexpand()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.id) { person in
                        personRow(person)
                        Separator()
                    }
                    loadMoreFooter(visible: searchHasMorePeople, loading: false) {
                        runCore { await AppSession.shared.search?.loadMorePeople() }
                    }
                }
                .frame(maxWidth: 720)
            }
            .vexpand()
        }
    }

    @ViewBuilder func personRow(_ person: PersonRowSnapshot) -> Body {
        HStack(spacing: 10) {
            remoteAvatar(url: person.avatarURL, name: person.name, size: 40)
                .valign(.start)
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(person.name)
                        .ellipsize()
                        .style("heading")
                        .halign(.start)
                    Text("@\(person.handle)")
                        .ellipsize()
                        .style("dim-label")
                        .hexpand()
                        .halign(.start)
                    if person.isFollowing {
                        Text("Following")
                            .style("caption")
                            .style("dim-label")
                    }
                }
                if !person.bio.isEmpty {
                    Text(person.bio)
                        .wrap()
                        .lines(3)
                        .ellipsize()
                        .style("dim-label")
                        .halign(.start)
                }
            }
            .hexpand()
            Symbol(icon: .custom(name: "go-next-symbolic"))
                .style("dim-label")
        }
        .padding(10)
        .onClick { openProfile(actor: person.id) }
    }

    @ViewBuilder var searchHashtagList: Body {
        let rows = searchHashtagRows
        if rows.isEmpty {
            StatusPage(
                "No hashtags yet",
                icon: .custom(name: "system-search-symbolic"),
                description: "Hashtags from matching posts appear here."
            )
            .vexpand()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.self) { tag in
                        Button("#\(tag)") { openHashtagSearch(tag) }
                            .flat()
                            .halign(.start)
                            .padding(6)
                        Separator()
                    }
                }
                .frame(maxWidth: 720)
            }
            .vexpand()
        }
    }

    @ViewBuilder var searchFeedList: Body {
        let rows = searchFeedRows
        if rows.isEmpty {
            StatusPage(
                "No feeds found",
                icon: .custom(name: "view-list-symbolic"),
                description: "Public feeds matching the words you typed appear here."
            )
            .vexpand()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.id) { feed in
                        feedRow(feed)
                        Separator()
                    }
                }
                .frame(maxWidth: 720)
            }
            .vexpand()
        }
    }

    @ViewBuilder func feedRow(_ feed: FeedRowSnapshot) -> Body {
        HStack(spacing: 10) {
            remoteAvatar(url: feed.avatarURL, name: feed.name, size: 40)
                .valign(.start)
            VStack(spacing: 2) {
                Text(feed.name)
                    .ellipsize()
                    .style("heading")
                    .halign(.start)
                Text(feed.subtitle)
                    .ellipsize()
                    .style("dim-label")
                    .style("caption")
                    .halign(.start)
                if !feed.description.isEmpty {
                    Text(feed.description)
                        .wrap()
                        .lines(2)
                        .ellipsize()
                        .style("dim-label")
                        .halign(.start)
                }
            }
            .hexpand()
            .onClick { openFeed(uri: feed.id, name: feed.name) }
            Button(feed.isSubscribed ? "Subscribed" : "Subscribe") { toggleFeedSubscription(feed) }
                .style("suggested-action", active: !feed.isSubscribed)
                .pill()
                .valign(.center)
        }
        .padding(10)
    }

    func openFeed(uri: String, name: String) {
        sidebarSelection = PaneID.feedPrefix + uri
        if narrow { showContent = true }
        runCore { await AppSession.shared.timeline?.setFeedSource(.custom(uri: uri, displayName: name)) }
    }

    func toggleFeedSubscription(_ feed: FeedRowSnapshot) {
        runCore {
            let service = AppSession.shared.service
            if feed.isSubscribed {
                await SavedFeedsStore.shared.unsubscribe(uri: feed.id, service: service)
            } else if let result = AppSession.shared.search?.feedResults.first(where: { $0.uri == feed.id }) {
                await SavedFeedsStore.shared.subscribe(result.asCustomFeed, pinned: true, service: service)
            }
        }
        showToast(feed.isSubscribed ? "Unsubscribed" : "Subscribed — pinned to the sidebar")
    }

    func loadMoreSearchPosts() {
        runCore { await AppSession.shared.search?.loadMorePosts() }
    }
}
