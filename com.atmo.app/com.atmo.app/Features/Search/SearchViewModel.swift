import Foundation
import ATProtoKit
import Observation

// MARK: - Search Category

enum SearchCategory: String, CaseIterable, Identifiable {
    case posts    = "Posts"
    case people   = "People"
    case hashtags = "Hashtags"

    var id: String { rawValue }

    var icon: String {
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
final class SearchViewModel {

    // MARK: Public State

    var query: String = ""
    var selectedCategory: SearchCategory = .posts

    var postResults:    [PostItem]     = []
    var peopleResults:  [ProfileModel] = []
    var hashtagResults: [String]       = []   // derived from query + post text

    var isLoading: Bool = false
    var error: String?  = nil

    // MARK: Private

    private let service: ATProtoService

    /// In-flight search task — cancelled and replaced on every new query keystroke.
    private var searchTask: Task<Void, Never>? = nil

    /// 5-minute auto-clear timer — started on disappear, cancelled on reappear.
    private var clearTask: Task<Void, Never>? = nil

    /// Minimum query length before any network search is attempted.
    private static let minQueryLength: Int = 2
    /// Debounce window before hitting the network (ms).
    private static let debounceMs: Int    = 500
    /// Idle time before results are freed from memory (seconds).
    private static let autoClearSec: Double = 5 * 60

    // MARK: Init

    init(service: ATProtoService) {
        self.service = service
    }

    // MARK: - Query Change

    /// Drive this from `.onChange(of: viewModel.query)` in the view.
    func onQueryChanged(_ newQuery: String) {
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
    func onAppear() {
        clearTask?.cancel()
        clearTask = nil
    }

    /// Call from `.onDisappear` — starts a 5-minute countdown.
    /// If the user doesn't return, results are freed and the query is reset.
    func onDisappear() {
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

        postResults    = posts
        peopleResults  = people
        hashtagResults = tags
        isLoading      = false
    }

    // MARK: - Category Fetchers

    private func fetchPosts(query: String, kit: ATProtoKit) async -> [PostItem] {
        do {
            let output = try await kit.searchPosts(matching: query, limit: 25)
            return output.posts.map { PostItem(postView: $0) }
        } catch {
            return []
        }
    }

    private func fetchPeople(query: String, kit: ATProtoKit) async -> [ProfileModel] {
        do {
            let output = try await kit.searchActors(matching: query, limit: 25)
            return output.actors.map { ProfileModel(searchResult: $0) }
        } catch {
            return []
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
    func activateHashtag(_ tag: String) {
        let q = "#\(tag)"
        query = q
        selectedCategory = .hashtags
        onQueryChanged(q)
    }

    // MARK: - Helpers

    func clearResults() {
        searchTask?.cancel()
        searchTask = nil
        postResults    = []
        peopleResults  = []
        hashtagResults = []
        isLoading      = false
        error          = nil
    }
}
