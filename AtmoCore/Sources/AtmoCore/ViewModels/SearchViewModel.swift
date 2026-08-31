import Foundation
import ATProtoKit
import Observation

// MARK: - Search Category

public enum SearchCategory: String, CaseIterable, Identifiable {
    case posts    = "Posts"
    case people   = "People"
    case hashtags = "Hashtags"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .posts:    return "text.bubble"
        case .people:   return "person.2"
        case .hashtags: return "number"
        }
    }
}

// MARK: - SearchViewModel

@Observable
@MainActor
public final class SearchViewModel {

    // MARK: Public State

    public var query: String = ""
    public var selectedCategory: SearchCategory = .posts

    /// Post-result ranking. Defaults to Top; trending-topic taps reset it.
    public enum SearchSort: String, CaseIterable, Identifiable, Sendable {
        case top
        case latest

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .top:    return "Top"
            case .latest: return "Latest"
            }
        }
        var ranking: AppBskyLexicon.Feed.SearchPosts.SortRanking {
            switch self {
            case .top:    return .top
            case .latest: return .latest
            }
        }
    }

    public private(set) var sort: SearchSort = .top
    /// Non-nil while the current results came from tapping a topic (the
    /// Explore surface) — drives the AI topic-summary card. Typing a
    /// query by hand clears it.
    public private(set) var summaryTopic: String? = nil
    /// Whether more post-result pages exist beyond what's loaded.
    public private(set) var hasMorePosts: Bool = false
    /// Whether more people-result pages exist beyond what's loaded.
    public private(set) var hasMorePeople: Bool = false

    public var postResults:    [PostItem]     = []
    public var peopleResults:  [ProfileModel] = []
    public var hashtagResults: [String]       = []   // derived from query + post text

    public var isLoading: Bool = false
    public var error: String?  = nil

    // MARK: Private

    private let service: ATProtoService

    /// In-flight search task — cancelled and replaced on every new query keystroke.
    private var searchTask: Task<Void, Never>? = nil
    /// Pagination cursor for the post results.
    private var postsCursor: String? = nil
    /// Pagination cursor for the people results.
    private var peopleCursor: String? = nil
    private var isLoadingMore = false

    /// 5-minute auto-clear timer — started on disappear, cancelled on reappear.
    private var clearTask: Task<Void, Never>? = nil

    /// Minimum query length before any network search is attempted.
    private static let minQueryLength: Int = 2
    /// Debounce window before hitting the network (ms).
    private static let debounceMs: Int    = 500
    /// Idle time before results are freed from memory (seconds).
    private static let autoClearSec: Double = 5 * 60

    // MARK: Init

    public init(service: ATProtoService) {
        self.service = service
    }

    // MARK: - Query Change

    /// Switches Top/Latest and re-runs the current query under the new
    /// ranking.
    public func setSort(_ newSort: SearchSort) {
        guard newSort != sort else { return }
        sort = newSort
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minQueryLength else { return }
        searchTask?.cancel()
        searchTask = Task {
            isLoading = true
            await performSearch(query: trimmed)
        }
    }

    /// Drive this from `.onChange(of: viewModel.query)` in the view.
    public func onQueryChanged(_ newQuery: String) {
        summaryTopic = nil
        // Cancel any in-flight search immediately so stale results are not
        // applied after the user has already typed more characters.
        searchTask?.cancel()
        searchTask = nil

        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        // Below minimum length — clear and stop. Never set isLoading here so
        // the view doesn't tear down and dismiss the keyboard.
        guard trimmed.count >= Self.minQueryLength else {
            clearResults()
            return
        }

        // Debounce: wait for the user to pause before hitting the network.
        // isLoading is NOT set here — it is only set inside the Task after the
        // sleep, so typing continuously never causes a spinner flash or a view
        // rebuild that would dismiss the keyboard / reset focus.
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(Self.debounceMs))
            guard !Task.isCancelled else { return }
            isLoading = true
            await performSearch(query: trimmed)
        }
    }

    // MARK: - View Lifecycle

    /// Call from `.onAppear` — cancels any pending memory-clear countdown.
    public func onAppear() {
        clearTask?.cancel()
        clearTask = nil
    }

    /// Call from `.onDisappear` — starts a 5-minute countdown.
    /// If the user doesn't return, results are freed and the query is reset.
    public func onDisappear() {
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(Self.autoClearSec))
            guard !Task.isCancelled else { return }
            clearResults()
            query = ""
        }
    }

    // MARK: - Search Execution

    private func performSearch(query: String) async {
        guard let kit = service.atProtoKit else { isLoading = false; return }

        error = nil

        // Fan out posts + people searches concurrently to minimise latency.
        // Hashtag results are derived locally — no extra network request needed.
        async let postsTask   = fetchPosts(query: query, kit: kit)
        async let peopleTask  = fetchPeople(query: query, kit: kit)
        async let tagsTask    = deriveHashtags(from: query)

        let (posts, people, tags) = await (postsTask, peopleTask, tagsTask)

        guard !Task.isCancelled else { return }

        postResults    = posts.items
        postsCursor    = posts.cursor
        hasMorePosts   = posts.cursor != nil
        peopleResults  = people.items
        peopleCursor   = people.cursor
        hasMorePeople  = people.cursor != nil
        hashtagResults = tags
        // Hashtags appearing in the result posts are relevant too.
        mergeHashtags(from: posts.items)
        isLoading      = false
    }

    /// Loads the next page of post results (infinite scroll). Appends
    /// URI-deduplicated, and feeds newly seen hashtags into the hashtag
    /// category as pages arrive.
    public func loadMorePosts() async {
        guard hasMorePosts, !isLoadingMore, !isLoading,
              let cursor = postsCursor,
              let kit = service.atProtoKit else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minQueryLength else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            // Top-ranked search pages can overlap earlier ones; an
            // all-duplicate page would append nothing, the tail row would
            // never change, and infinite scroll would silently stall.
            // Skip ahead (bounded) until something new arrives.
            var pageCursor: String? = cursor
            var appended = 0
            var hops = 0
            while appended == 0, let current = pageCursor, hops < 3 {
                let output = try await kit.searchPosts(
                    matching: trimmed,
                    sortRanking: sort.ranking,
                    limit: 25,
                    cursor: current
                )
                let newPosts = output.posts.map { PostItem(postView: $0) }
                let existing = Set(postResults.map(\.uri))
                let fresh = newPosts.filter { !existing.contains($0.uri) }
                postResults.append(contentsOf: fresh)
                appended += fresh.count
                mergeHashtags(from: newPosts)
                pageCursor = output.cursor
                hops += 1
                if output.cursor == nil { break }
            }
            postsCursor = pageCursor
            hasMorePosts = pageCursor != nil
        } catch {
            hasMorePosts = false
        }
    }

    /// Folds hashtags found in post texts into the hashtag results,
    /// deduplicated case-insensitively, order of first appearance.
    private func mergeHashtags(from posts: [PostItem]) {
        let found = Self.hashtags(in: posts.map(\.text))
        guard !found.isEmpty else { return }
        var seen = Set(hashtagResults.map { $0.lowercased() })
        for tag in found where seen.insert(tag.lowercased()).inserted {
            hashtagResults.append(tag)
        }
    }

    /// Pure hashtag extraction (unit-tested): every #tag in the texts,
    /// deduplicated case-insensitively, in order of first appearance.
    nonisolated static func hashtags(in texts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for text in texts {
            for token in text.components(separatedBy: .whitespacesAndNewlines) {
                guard token.hasPrefix("#"), token.count > 1 else { continue }
                let tag = String(
                    token.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                )
                guard !tag.isEmpty, tag.rangeOfCharacter(from: .letters) != nil else { continue }
                if seen.insert(tag.lowercased()).inserted {
                    result.append(tag)
                }
            }
        }
        return result
    }

    // MARK: - Category Fetchers

    private func fetchPosts(query: String, kit: ATProtoKit) async -> (items: [PostItem], cursor: String?) {
        do {
            let output = try await kit.searchPosts(
                matching: query,
                sortRanking: sort.ranking,
                limit: 25
            )
            return (output.posts.map { PostItem(postView: $0) }, output.cursor)
        } catch {
            return ([], nil)
        }
    }

    private func fetchPeople(query: String, kit: ATProtoKit) async -> (items: [ProfileModel], cursor: String?) {
        do {
            let output = try await kit.searchActors(matching: query, limit: 25)
            return (output.actors.map { ProfileModel(searchResult: $0) }, output.cursor)
        } catch {
            return ([], nil)
        }
    }

    /// Loads the next page of people results (infinite scroll).
    public func loadMorePeople() async {
        guard hasMorePeople, !isLoadingMore, !isLoading,
              let cursor = peopleCursor,
              let kit = service.atProtoKit else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minQueryLength else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            // Same duplicate-page skip-ahead as loadMorePosts.
            var pageCursor: String? = cursor
            var appended = 0
            var hops = 0
            while appended == 0, let current = pageCursor, hops < 3 {
                let output = try await kit.searchActors(matching: trimmed, limit: 25, cursor: current)
                let newPeople = output.actors.map { ProfileModel(searchResult: $0) }
                let existing = Set(peopleResults.map(\.did))
                let fresh = newPeople.filter { !existing.contains($0.did) }
                peopleResults.append(contentsOf: fresh)
                appended += fresh.count
                pageCursor = output.cursor
                hops += 1
                if output.cursor == nil { break }
            }
            peopleCursor = pageCursor
            hasMorePeople = pageCursor != nil
        } catch {
            hasMorePeople = false
        }
    }

    /// Extracts explicit #hashtags typed in the search query.
    /// Bluesky doesn't yet expose a dedicated hashtag search endpoint;
    /// surface what the user typed plus any tags found in post results.
    private func deriveHashtags(from query: String) async -> [String] {
        // Tokens beginning with '#' are treated as hashtag queries
        let fromQuery = query
            .components(separatedBy: .whitespaces)
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .map { String($0.dropFirst()) }

        // Deduplicate while preserving order
        var seen = Set<String>()
        return fromQuery.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Hashtag Activation

    /// Pre-fills the query with `#<tag>` and immediately runs a search.
    /// Called by the environment `HashtagSearchAction` when a #hashtag is tapped
    /// anywhere in the feed or thread views.
    public func activateHashtag(_ tag: String) {
        sort = .top
        let q = "#\(tag)"
        query = q
        selectedCategory = .hashtags
        onQueryChanged(q)
    }

    /// Pre-fills the query with a trending/suggested topic and runs a
    /// post search — the Explore sections' tap action.
    public func activateTopic(_ topic: String) {
        sort = .top
        query = topic
        selectedCategory = .posts
        onQueryChanged(topic)
        // After onQueryChanged (which clears it for typed queries).
        summaryTopic = topic
    }

    // MARK: - Helpers

    public func clearResults() {
        searchTask?.cancel()
        searchTask = nil
        postResults    = []
        peopleResults  = []
        hashtagResults = []
        isLoading      = false
        error          = nil
    }
}
