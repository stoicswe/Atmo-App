import Foundation
import ATProtoKit
import Observation

@Observable
@MainActor
public final class TimelineViewModel {

    public private(set) var posts: [PostItem] = []
    public private(set) var isLoading: Bool = false
    public private(set) var isRefreshing: Bool = false

    /// URIs of silently-prepended posts the user hasn't scrolled past yet.
    /// Rows report themselves seen via `markNewPostSeen(uri:)`, so the
    /// pill's count and avatar stack shrink live as the user scrolls up
    /// through the new content.
    private var unseenNewPostURIs: Set<String> = []

    /// How many avatars the new-posts pill shows before collapsing the
    /// rest into a "+N" badge.
    public static let pillAvatarLimit = 5

    /// Number of not-yet-seen new posts (drives the "new posts" pill).
    public var newPostsCount: Int { unseenNewPostURIs.count }

    /// One post per unique author among the unseen new posts, in feed
    /// order (newest first), capped at `pillAvatarLimit` for the pill's
    /// avatar stack.
    public var newPostAuthors: [PostItem] {
        var seenDIDs = Set<String>()
        var authors: [PostItem] = []
        for post in posts where unseenNewPostURIs.contains(post.uri) {
            if seenDIDs.insert(post.authorDID).inserted {
                authors.append(post)
                if authors.count == Self.pillAvatarLimit { break }
            }
        }
        return authors
    }

    /// How many unique unseen authors did NOT fit in the pill's avatar
    /// stack — the pill renders this as "+N".
    public var newPostsOverflowAuthorCount: Int {
        var seenDIDs = Set<String>()
        for post in posts where unseenNewPostURIs.contains(post.uri) {
            seenDIDs.insert(post.authorDID)
        }
        return max(0, seenDIDs.count - Self.pillAvatarLimit)
    }

    /// The highest pre-existing post still rendered after the most recent
    /// silent prepend. UIs whose scroll views don't preserve position on
    /// insert (e.g. the GTK front end) can re-anchor the viewport to it;
    /// SwiftUI's `.scrollPosition(id:)` handles this natively and ignores it.
    public private(set) var newPostsAnchorURI: String? = nil
    public private(set) var error: Error? = nil
    private var cursor: String? = nil
    private var hasMore: Bool = true
    /// Guards against concurrent checkForNewPosts calls (e.g. rapid onAppear firings)
    private var isCheckingForNew: Bool = false

    private let service: ATProtoService

    /// Retained background task that sleeps between periodic silent refresh ticks.
    /// `nonisolated(unsafe)` allows `deinit` (which is nonisolated in Swift 6) to
    /// cancel the task without an actor-isolation error. All reads/writes happen on
    /// the MainActor via the `@MainActor`-isolated methods that set these properties.
    @ObservationIgnored nonisolated(unsafe) private var refreshTimerTask: Task<Void, Never>? = nil
    /// Retained task that listens for foreground-resume notifications.
    @ObservationIgnored nonisolated(unsafe) private var sceneObservationTask: Task<Void, Never>? = nil
    /// Retained task that listens for app-backgrounded notifications.
    @ObservationIgnored nonisolated(unsafe) private var backgroundObservationTask: Task<Void, Never>? = nil
    /// Retained task that listens for the user submitting a post.
    @ObservationIgnored nonisolated(unsafe) private var postSubmitObservationTask: Task<Void, Never>? = nil

    public init(service: ATProtoService) {
        self.service = service
        // Defer observation setup to the next run-loop tick so `self` is fully
        // initialized before the tasks capture it.
        Task { @MainActor [weak self] in
            self?.startPeriodicRefresh()
            self?.startSceneObservation()
            self?.startPostSubmitObservation()
        }
    }

    deinit {
        refreshTimerTask?.cancel()
        sceneObservationTask?.cancel()
        backgroundObservationTask?.cancel()
        postSubmitObservationTask?.cancel()
    }

    // MARK: - Periodic Background Refresh

    /// Starts a looping background task that silently checks for new posts on
    /// the interval the platform configured (`Atmo.platform` — shorter on
    /// desktop, battery-friendlier on mobile). The task respects any in-flight
    /// loading operations (guarded by checkForNewPosts's own guards).
    ///
    /// Energy: the sleep carries a 10% tolerance so the OS can coalesce the
    /// wake-up with other timers instead of spinning the CPU up on its own.
    private func startPeriodicRefresh() {
        guard refreshTimerTask == nil else { return }
        let interval = Atmo.platform.timelineRefreshInterval
        refreshTimerTask = Task { [weak self] in
            // Wait one interval before the first tick so we don't double-fetch
            // on launch (loadInitial already runs at startup).
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(interval),
                    tolerance: .seconds(interval * 0.1)
                )
                guard !Task.isCancelled else { break }
                await self?.checkForNewPosts()
            }
        }
    }

    private func pausePeriodicRefresh() {
        refreshTimerTask?.cancel()
        refreshTimerTask = nil
    }

    /// Foreground/background lifecycle:
    ///   • app foregrounded → resume the poll timer and check immediately;
    ///   • app backgrounded → stop the timer entirely. While the user is
    ///     away, freshness is the job of the platforms' system-coalesced
    ///     background sync, not a live timer draining the battery.
    private func startSceneObservation() {
        if let foreground = Atmo.platform.foregroundNotification {
            sceneObservationTask = Task { [weak self] in
                let stream = NotificationCenter.default.signals(named: foreground)
                for await _ in stream {
                    guard !Task.isCancelled else { break }
                    self?.startPeriodicRefresh()
                    await self?.checkForNewPosts()
                }
            }
        }
        if let background = Atmo.platform.backgroundNotification {
            backgroundObservationTask = Task { [weak self] in
                let stream = NotificationCenter.default.signals(named: background)
                for await _ in stream {
                    guard !Task.isCancelled else { break }
                    self?.pausePeriodicRefresh()
                }
            }
        }
    }

    /// The user just submitted a post: pull the timeline's fresh head so
    /// their own post shows up right away. checkForNewPosts prepends behind
    /// the anchor, so the scroll position stays put.
    private func startPostSubmitObservation() {
        postSubmitObservationTask = Task { [weak self] in
            let stream = NotificationCenter.default.signals(named: .atmoDidSubmitPost)
            for await _ in stream {
                guard !Task.isCancelled else { break }
                // Give the AppView a beat to index the new post before
                // fetching, or the fresh head won't contain it yet.
                try? await Task.sleep(for: .seconds(1))
                await self?.checkForNewPosts()
            }
        }
    }

    // MARK: - Feed Source

    /// What this timeline shows: the reverse-chronological following feed,
    /// or one of the user's saved custom feed generators.
    public enum FeedSource: Hashable, Sendable {
        case following
        case custom(uri: String, displayName: String)

        public var displayName: String {
            switch self {
            case .following: return "Home"
            case .custom(_, let name): return name
            }
        }

        public var isFollowing: Bool {
            if case .following = self { return true }
            return false
        }
    }

    public private(set) var feedSource: FeedSource = .following

    /// Switches the timeline to another feed and reloads from its head.
    public func setFeedSource(_ source: FeedSource) async {
        guard source != feedSource else { return }
        feedSource = source
        clearNewPostsCount()
        await loadInitial()
    }

    /// One page from the current source, from `cursor` (nil = head).
    private func fetchPage(
        _ kit: ATProtoKit,
        cursor: String?
    ) async throws -> (feed: [AppBskyLexicon.Feed.FeedViewPostDefinition], cursor: String?) {
        switch feedSource {
        case .following:
            let output = try await kit.getTimeline(limit: 50, cursor: cursor)
            return (output.feed, output.cursor)
        case .custom(let uri, _):
            let output = try await kit.getFeed(by: uri, limit: 50, cursor: cursor)
            return (output.feed, output.cursor)
        }
    }

    // MARK: - Loading

    public func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        cursor = nil
        posts = []
        hasMore = true
        await fetch()
        isLoading = false
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        cursor = nil
        hasMore = true
        await fetch(replacing: true)
        isRefreshing = false
    }

    /// Silently checks for new posts at the top of the timeline without
    /// altering the current scroll position. New items are *prepended*
    /// so the user stays where they are. Call this when the user scrolls
    /// back to the top.
    ///
    /// Returns `(count, anchorURI)` where:
    ///   - `count` is the number of new posts prepended (0 if none)
    ///   - `anchorURI` is the URI of the first *previously existing* post, which
    ///     the caller should immediately scroll to (without animation) after the
    ///     prepend so the viewport doesn't jump as the content above it grows.
    @discardableResult
    public func checkForNewPosts() async -> (count: Int, anchorURI: String?) {
        // Hard guard: bail out if any loading is already in flight.
        // isCheckingForNew prevents concurrent calls from the same trigger
        // (e.g. rapid onAppear firings from LazyVStack recycling the anchor cell).
        guard !isLoading, !isRefreshing, !isCheckingForNew,
              let kit = service.atProtoKit else { return (0, nil) }
        isCheckingForNew = true
        defer { isCheckingForNew = false }

        do {
            // Fetch one page from the start (no cursor = freshest posts)
            let output = try await fetchPage(kit, cursor: nil)
            let fetched = output.feed.map { PostItem(feedPost: $0) }

            // Find which items are genuinely new. "Already in the list"
            // must cover everything the list REPRESENTS — the cells AND the
            // ancestors collapsed inside them: head pages re-deliver old
            // slices of known conversations (the root, an intermediate
            // reply) at their natural positions, and treating those as new
            // hoisted their whole cell above genuinely newer posts.
            let cellURIs = Set(posts.map { $0.uri })
            var representedURIs = cellURIs
            for post in posts {
                for ancestor in post.threadAncestors {
                    representedURIs.insert(ancestor.uri)
                }
            }
            let newItems = fetched.filter { !representedURIs.contains($0.uri) }

            guard !newItems.isEmpty else { return (0, nil) }

            // Collapse thread slices within the new batch, then again across
            // the seam between the new and existing posts, so a fresh reply
            // absorbs the cell its conversation already had further down.
            let deduped = Self.collapseThreadSlices(
                newItems + posts,
                enforceChronology: feedSource.isFollowing
            )
            posts = deduped

            // Track the new posts as "unseen" — but only ones that survived
            // dedup and will actually render, or the rows could never
            // report themselves seen and the pill would stick.
            let renderedURIs = Set(deduped.map(\.uri))
            unseenNewPostURIs.formUnion(
                newItems.map(\.uri).filter { renderedURIs.contains($0) }
            )

            // Anchor = the highest pre-existing CELL still rendered (an
            // ancestor URI never was a row, so it can't anchor a viewport);
            // the view keeps the viewport glued to it while new rows land.
            let anchorURI = deduped.first(where: { cellURIs.contains($0.uri) })?.uri
            newPostsAnchorURI = anchorURI

            return (newItems.count, anchorURI)
        } catch {
            // Silent failure — not worth surfacing an error for a background check
            return (0, nil)
        }
    }

    /// Called after the user acknowledges the new-posts pill (taps it or pull-refreshes).
    public func clearNewPostsCount() {
        unseenNewPostURIs = []
        newPostsAnchorURI = nil
    }

    /// Reports that the user's viewport reached this post. New-post rows
    /// call it as they appear, so scrolling up through the fresh content
    /// drains the pill one post at a time — its count drops and an
    /// author's avatar leaves the stack once their last unseen post has
    /// been passed.
    public func markNewPostSeen(uri: String) {
        guard unseenNewPostURIs.contains(uri) else { return }
        unseenNewPostURIs.remove(uri)
        if unseenNewPostURIs.isEmpty {
            newPostsAnchorURI = nil
        }
    }

    /// Whether more pages exist beyond the currently loaded posts —
    /// drives the manual "Load More" control when infinite scroll is off.
    public var canLoadMore: Bool {
        hasMore && cursor != nil
    }

    /// Timestamp of the last completed page fetch — throttles back-to-back
    /// loadMore calls.
    @ObservationIgnored private var lastLoadMoreAt: Date? = nil

    public func loadMore() async {
        guard hasMore, !isLoading, !isRefreshing, !isCheckingForNew, cursor != nil else { return }
        // Throttle: the tail row's onAppear can re-fire the instant each
        // page lands. During a pathological layout pass (e.g. a navigation
        // transition realizing the entire lazy feed) that grew the feed
        // without bound and froze the main thread. Real scrolling never
        // reaches the feed's end more often than twice a second.
        if let last = lastLoadMoreAt, Date().timeIntervalSince(last) < 0.5 { return }
        // Prevent concurrent loadMore calls from racing each other
        isLoading = true
        await fetch()
        lastLoadMoreAt = Date()
        isLoading = false
    }

    private func fetch(replacing: Bool = false) async {
        guard let kit = service.atProtoKit else { return }
        do {
            let output = try await fetchPage(kit, cursor: cursor)
            let newItems = output.feed.map { PostItem(feedPost: $0) }
            let dedupedItems = Self.collapseThreadSlices(
                newItems,
                enforceChronology: feedSource.isFollowing
            )
            if replacing || cursor == nil {
                // Full replace — deduplicate within the fresh batch itself
                // in case the API returns the same post twice (e.g. a repost
                // of a post that also appears organically on the same page).
                var seen = Set<String>()
                posts = dedupedItems.filter { seen.insert($0.uri).inserted }
            } else {
                // Append page — filter out anything already in the list.
                // Use URI as the canonical key (id == uri for normal posts;
                // reposts share the original URI so they won't create dupes).
                let existingURIs = Set(posts.map { $0.uri })
                let uniqueNew = dedupedItems.filter { !existingURIs.contains($0.uri) }
                posts.append(contentsOf: uniqueNew)
            }
            cursor = output.cursor
            hasMore = output.cursor != nil
            error = nil
        } catch {
            self.error = error
        }
    }

    /// Tidies raw timeline pages so one conversation occupies ONE feed cell
    /// instead of several scattered slices.
    ///
    /// The raw timeline includes every followed account's reply as its own
    /// feed item, so an active conversation appears as many separate cells,
    /// each re-rendering the same parents as inline context ("More in
    /// thread" soup). Two passes fix that:
    ///
    ///  1. Adjacent-parent suppression — drop post[i] when post[i+1] is its
    ///     direct reply; the reply's cell renders the parent inline.
    ///  2. Thread grouping — every organic (non-repost) post belongs to a
    ///     thread, keyed by its reply root (or itself for root posts). Only
    ///     one cell per thread survives: the newest post in it, placed at
    ///     the highest feed position any member occupied. The newest reply
    ///     renders its ancestors inline and the "More in thread" affordance
    ///     opens the full conversation, so nothing is lost.
    ///
    /// Reposts are exempt from both passes — "X reposted" is its own story
    /// — and exact-URI duplicates are handled by the fetch/prepend merges.
    /// Internal (not private) so the unit tests can exercise it directly.
    static func collapseThreadSlices(
        _ items: [PostItem],
        enforceChronology: Bool = true
    ) -> [PostItem] {
        guard items.count > 1 else { return items }

        // Pass 1: parent cell sitting directly above its own reply.
        var slices: [PostItem] = []
        slices.reserveCapacity(items.count)
        for (index, post) in items.enumerated() {
            if post.reason == nil,
               index + 1 < items.count,
               items[index + 1].replyParentURI == post.uri {
                continue
            }
            slices.append(post)
        }

        // Pass 2: one cell per thread.
        func threadKey(_ post: PostItem) -> String {
            post.replyRootURI ?? post.replyParentURI ?? post.uri
        }

        // Representative per thread: the newest member (ties prefer a reply
        // over the bare root, since replies carry their context inline).
        var newestInThread: [String: PostItem] = [:]
        for post in slices where post.reason == nil {
            let key = threadKey(post)
            if let current = newestInThread[key] {
                let isNewer = post.indexedAt > current.indexedAt
                    || (post.indexedAt == current.indexedAt
                        && post.replyParentURI != nil
                        && current.replyParentURI == nil)
                if isNewer { newestInThread[key] = post }
            } else {
                newestInThread[key] = post
            }
        }

        // URI uniqueness is an invariant of the output: a repost carries the
        // ORIGINAL post's URI, so a repost of a reply plus that same reply
        // emitted as its thread's representative used to produce two rows
        // with one identity — which crashes SwiftUI's lazy ForEach. (The
        // initial-load path had a dedup filter after this; the silent
        // prepend path did not, and crashed at launch on feeds containing
        // such a repost.)
        var emittedThreads = Set<String>()
        var seenURIs = Set<String>()
        var result: [PostItem] = []
        result.reserveCapacity(slices.count)
        for post in slices {
            if post.reason != nil {
                guard seenURIs.insert(post.uri).inserted else { continue }
                result.append(post)
                continue
            }
            let key = threadKey(post)
            guard emittedThreads.insert(key).inserted else { continue }
            let representative = newestInThread[key] ?? post
            guard seenURIs.insert(representative.uri).inserted else { continue }
            result.append(representative)
        }

        // The FOLLOWING feed is chronological — enforce it on the way out
        // (cells can end up out of order when slices merge across a seam).
        // Custom feeds are ranked by their generator: their order is the
        // content, so it must pass through untouched.
        guard enforceChronology else { return result }
        return result
            .enumerated()
            .sorted { a, b in
                if a.element.feedSortDate != b.element.feedSortDate {
                    return a.element.feedSortDate > b.element.feedSortDate
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: - Thread Post Seeding

    /// Replaces the posts array with an arbitrary list of PostItems.
    /// Used by ThreadView to seed the ViewModel with the root post and all
    /// reply posts so that toggleLike / toggleRepost can find them by ID.
    public func seedPosts(_ items: [PostItem]) {
        posts = items
    }

    // MARK: - Quote

    /// Called after the user successfully submits a quote post.
    /// Marks the original post as quoted in the local list so the repost button
    /// immediately reflects the action — the API has no viewer.isQuoted field.
    public func markAsQuoted(post: PostItem) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[index].isQuoted = true
        posts[index].quoteCount += 1
    }

    // MARK: - Like

    public func toggleLike(post: PostItem) async {
        guard let bluesky = service.atProtoBluesky,
              let index = posts.firstIndex(where: { $0.id == post.id }) else { return }

        if posts[index].isLiked {
            // Unlike
            guard let likeURI = posts[index].likeURI else { return }
            posts[index].isLiked = false
            posts[index].likeCount = max(0, posts[index].likeCount - 1)
            posts[index].likeURI = nil
            do {
                try await bluesky.deleteRecord(.recordURI(atURI: likeURI))
            } catch {
                // Rollback optimistic update
                posts[index].isLiked = true
                posts[index].likeCount += 1
                posts[index].likeURI = likeURI
                self.error = error
            }
        } else {
            // Like
            posts[index].isLiked = true
            posts[index].likeCount += 1
            do {
                let result = try await bluesky.createLikeRecord(
                    ComAtprotoLexicon.Repository.StrongReference(
                        recordURI: post.uri,
                        cidHash: post.cid
                    )
                )
                posts[index].likeURI = result.recordURI
            } catch {
                // Rollback
                posts[index].isLiked = false
                posts[index].likeCount = max(0, posts[index].likeCount - 1)
                posts[index].likeURI = nil
                self.error = error
            }
        }
    }

    // MARK: - Repost

    public func toggleRepost(post: PostItem) async {
        guard let bluesky = service.atProtoBluesky,
              let index = posts.firstIndex(where: { $0.id == post.id }) else { return }

        if posts[index].isReposted {
            guard let repostURI = posts[index].repostURI else { return }
            posts[index].isReposted = false
            posts[index].repostCount = max(0, posts[index].repostCount - 1)
            posts[index].repostURI = nil
            do {
                try await bluesky.deleteRecord(.recordURI(atURI: repostURI))
            } catch {
                posts[index].isReposted = true
                posts[index].repostCount += 1
                posts[index].repostURI = repostURI
                self.error = error
            }
        } else {
            posts[index].isReposted = true
            posts[index].repostCount += 1
            do {
                let result = try await bluesky.createRepostRecord(
                    ComAtprotoLexicon.Repository.StrongReference(
                        recordURI: post.uri,
                        cidHash: post.cid
                    )
                )
                posts[index].repostURI = result.recordURI
            } catch {
                posts[index].isReposted = false
                posts[index].repostCount = max(0, posts[index].repostCount - 1)
                posts[index].repostURI = nil
                self.error = error
            }
        }
    }
}
