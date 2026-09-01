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

    /// Wider post pool assembled invisibly in the background: the topic's
    /// own backing feed (when Bluesky supplied one) plus contextual query
    /// variants, merged with the visible results. Feeds the AI summary so
    /// it isn't starved when the headline phrase alone matches few posts.
    public private(set) var summaryCorpus: [PostItem] = []

    /// What the topic-summary card should summarize: the enriched corpus
    /// when it exists, else the visible results.
    public var summaryPosts: [PostItem] {
        summaryCorpus.isEmpty ? postResults : summaryCorpus
    }

    public var isLoading: Bool = false
    public var error: String?  = nil

    // MARK: Private

    private let service: ATProtoService

    /// In-flight search task — cancelled and replaced on every new query keystroke.
    private var searchTask: Task<Void, Never>? = nil
    /// Background result-enrichment task (topic feed + query variants) —
    /// cancelled whenever the query moves on.
    private var enrichmentTask: Task<Void, Never>? = nil
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
        // Typing a DIFFERENT query dismisses the topic summary. The
        // equality check matters: activateTopic sets `query`
        // programmatically, which makes the search bar's .onChange echo
        // back into this method one view-update later — an unconditional
        // reset here wiped the just-set summary topic every single time,
        // so the card never appeared.
        if newQuery != summaryTopic {
            summaryTopic = nil
            enrichmentTask?.cancel()
            enrichmentTask = nil
            summaryCorpus = []
        }
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

        // A hand-typed query with sparse results gets the same invisible
        // widening as topics (the user's own words, re-combined — quoted
        // phrase and keyword core; no trend feed or description exist
        // here). Topic taps already started their enrichment.
        if summaryTopic == nil, posts.items.count < 10, enrichmentTask == nil {
            startEnrichment(query: query, description: nil, feedURI: nil)
        }
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
    /// "Search posts" from a profile's ··· menu: pre-fills the query with
    /// the `from:` operator for that account and runs a post search.
    public func activateAuthorSearch(handle: String) {
        sort = .top
        let q = "from:\(handle)"
        query = q
        selectedCategory = .posts
        onQueryChanged(q)
    }

    public func activateHashtag(_ tag: String) {
        sort = .top
        let q = "#\(tag)"
        query = q
        selectedCategory = .hashtags
        onQueryChanged(q)
    }

    /// Pre-fills the query with a trending/suggested topic and runs a
    /// post search — the Explore sections' tap action. `description` and
    /// `feedURI` (when the trend carried them) drive invisible background
    /// enrichment: the trend's own curated feed plus contextual query
    /// variants widen the pool the AI summary draws from, and backfill
    /// the visible results when the headline phrase alone matches little.
    public func activateTopic(
        _ topic: String,
        description: String? = nil,
        feedURI: String? = nil
    ) {
        sort = .top
        query = topic
        selectedCategory = .posts
        onQueryChanged(topic)
        // After onQueryChanged (which clears it for typed queries).
        summaryTopic = topic
        startEnrichment(query: topic, description: description, feedURI: feedURI)
    }

    // MARK: - Background Result Enrichment

    /// Invisible recall-widening pass, the way Bluesky's own app sources
    /// a trend's page: pull the trend's backing FEED (its curated posts),
    /// then run contextual query variants (quoted phrase, keyword core,
    /// description-derived proper nouns), merge everything URI-deduped
    /// into `summaryCorpus`, and — when the visible results are sparse —
    /// backfill the results list itself with the extra on-topic posts.
    private func startEnrichment(query: String, description: String?, feedURI: String?) {
        enrichmentTask?.cancel()
        summaryCorpus = []
        guard let kit = service.atProtoKit else { return }

        enrichmentTask = Task { [weak self] in
            // Let the primary (visible) search settle first — it is
            // debounced and its arrival REPLACES postResults, which would
            // wipe an early backfill. Bounded wait; proceeds regardless
            // after ~5s so a zero-result primary still gets enriched.
            for _ in 0..<20 {
                guard let self, !Task.isCancelled else { return }
                if !self.isLoading, !self.postResults.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !Task.isCancelled else { return }

            // Efficiency gates (this whole pass is invisible — its only
            // consumers are the AI summary and sparse-result backfill):
            //  • when summaries are off and the visible results are
            //    already healthy, there is nothing to gain — do nothing;
            //  • stop issuing requests once the pool is big enough. The
            //    trend's feed alone usually meets the target, so the
            //    typical rich-topic tap costs ONE extra request.
            let summariesWanted = UserDefaults.standard.bool(forKey: TopicSummaryStore.enabledKey)
            let resultsAreSparse = self.postResults.count < 10
            guard summariesWanted || resultsAreSparse else { return }
            let poolTarget = 40

            var extras: [PostItem] = []

            // The trend's own feed — the strongest source of on-topic
            // posts, independent of whether they contain the headline.
            if let feedURI {
                if let output = try? await kit.getFeed(by: feedURI, limit: 50) {
                    extras += output.feed.map { PostItem(feedPost: $0) }
                }
                guard !Task.isCancelled else { return }
            }

            // Contextual query variants, most precise first; skipped
            // entirely once the pool target is met.
            for variant in SearchQueryExpansion.variants(for: query, description: description)
            where extras.count < poolTarget {
                if let output = try? await kit.searchPosts(
                    matching: variant,
                    sortRanking: SearchSort.top.ranking,
                    limit: 25
                ) {
                    extras += output.posts.map { PostItem(postView: $0) }
                }
                guard !Task.isCancelled else { return }
            }
            guard !extras.isEmpty else { return }

            // Corpus: visible results lead (they matched the exact
            // phrase), then the widened pool.
            self.summaryCorpus = Self.mergedUnique(
                primary: self.postResults, extras: extras, cap: 80
            )

            // Sparse visible results get quietly backfilled with the
            // on-topic extras so the page itself isn't thin either.
            if self.postResults.count < 10 {
                self.postResults = Self.mergedUnique(
                    primary: self.postResults, extras: extras, cap: 50
                )
                self.mergeHashtags(from: self.postResults)
            }
        }
    }

    /// URI-deduplicated merge preserving order: all of `primary`, then
    /// every unseen post from `extras`, capped. Pure; unit-tested.
    nonisolated static func mergedUnique(
        primary: [PostItem],
        extras: [PostItem],
        cap: Int
    ) -> [PostItem] {
        var seen = Set<String>()
        var merged: [PostItem] = []
        for post in primary + extras where seen.insert(post.uri).inserted {
            merged.append(post)
            if merged.count == cap { break }
        }
        return merged
    }

    // MARK: - Helpers

    public func clearResults() {
        searchTask?.cancel()
        searchTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        summaryCorpus  = []
        postResults    = []
        peopleResults  = []
        hashtagResults = []
        isLoading      = false
        error          = nil
    }
}
