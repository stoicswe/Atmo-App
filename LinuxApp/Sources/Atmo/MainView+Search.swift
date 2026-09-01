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
    }

    // MARK: - Model snapshots

    var searchIsLoading: Bool {
        _ = tick
        return onMain { AppSession.shared.search?.isLoading ?? false }
    }

    var searchPostRows: [PostRowSnapshot] {
        _ = tick
        return onMain {
            (AppSession.shared.search?.postResults ?? []).map(PostRowSnapshot.init(post:))
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
                    bio: profile.description ?? ""
                )
            }
        }
    }

    var searchHashtagRows: [String] {
        _ = tick
        return onMain { AppSession.shared.search?.hashtagResults ?? [] }
    }

    // MARK: - Pane

    @ViewBuilder var searchPane: Body {
        VStack(spacing: 0) {
            SearchEntry()
                .placeholderText("Search posts, people, hashtags")
                .text($searchQuery)
                .padding(10)
            HStack(spacing: 6) {
                ForEach(SearchCategory.allCases, id: \.rawValue) { category in
                    Button(category.rawValue) { searchCategory = category.rawValue }
                        .flat(searchCategory != category.rawValue)
                        .style("suggested-action", active: searchCategory == category.rawValue)
                }
            }
            .halign(.center)
            .padding(4)
            Separator()
            searchResults
        }
        .onAppear { syncSearchQuery() }
    }

    /// Adwaita re-renders on every keystroke (the SearchEntry binding);
    /// this hands the new text to the shared SearchViewModel exactly once
    /// per change — the debounce, minimum length, and fan-out (posts +
    /// people + hashtags) all live in core.
    func syncSearchQuery() {
        onMain {
            guard let search = AppSession.shared.search,
                  search.query != searchQuery else { return }
            search.query = searchQuery
            search.onQueryChanged(searchQuery)
        }
    }

    @ViewBuilder var searchResults: Body {
        // Keep the view model fed before reading results (body runs on
        // every keystroke; the call is a no-op when the text is unchanged).
        let _ = syncSearchQuery()
        if searchQuery.trimmingCharacters(in: .whitespaces).count < 2 {
            StatusPage(
                "Search Bluesky",
                icon: .custom(name: "system-search-symbolic"),
                description: "Posts, people, and hashtags."
            )
            .vexpand()
        } else if searchIsLoading {
            Spinner()
                .vexpand()
                .valign(.center)
        } else {
            switch SearchCategory(rawValue: searchCategory) ?? .posts {
            case .posts: searchPostList
            case .people: searchPeopleList
            case .hashtags: searchHashtagList
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
                        // Read-only rows: SearchViewModel has no
                        // like/repost toggles (tracked in PORTING.md);
                        // open the thread to interact.
                        postRow(row, actions: .readOnly)
                        Separator()
                    }
                    Button("Load More") { loadMoreSearchPosts() }
                        .flat()
                        .padding(8)
                }
            }
            .vexpand()
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
                                }
                                if !person.bio.isEmpty {
                                    Text(person.bio)
                                        .wrap()
                                        .style("dim-label")
                                        .halign(.start)
                                }
                            }
                            .hexpand()
                        }
                        .padding(10)
                        Separator()
                    }
                }
            }
            .vexpand()
        }
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
                        Button("#\(tag)") {
                            searchQuery = "#\(tag)"
                            searchCategory = SearchCategory.posts.rawValue
                        }
                        .flat()
                        .halign(.start)
                        .padding(6)
                        Separator()
                    }
                }
            }
            .vexpand()
        }
    }

    func loadMoreSearchPosts() {
        runCore { await AppSession.shared.search?.loadMorePosts() }
    }
}
