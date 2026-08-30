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

    /// The URI of the first post that existed *before* the most recent silent prepend.
    /// The view should immediately (no animation) scroll to this URI after new posts are
    /// prepended so the existing content doesn't visually jump upward.
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

    public init(service: ATProtoService) {
        self.service = service
        // Defer observation setup to the next run-loop tick so `self` is fully
        // initialized before the tasks capture it.
        Task { @MainActor [weak self] in
            self?.startPeriodicRefresh()
            self?.startSceneObservation()
        }
    }

    deinit {
        refreshTimerTask?.cancel()
        sceneObservationTask?.cancel()
        backgroundObservationTask?.cancel()
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
            // Capture the first existing post's URI BEFORE mutating — the caller
            // will use this to re-anchor the scroll position after prepending.
            let anchorURI = posts.first?.uri

            // Fetch one page from the start (no cursor = freshest posts)
            let output = try await kit.getTimeline(limit: 50, cursor: nil)
            let fetched = output.feed.map { PostItem(feedPost: $0) }

            // Find which items are genuinely new (not already in the list).
            // Use URI as the canonical identity — two entries with the same URI
            // are the same post regardless of repost wrapping.
            let existingURIs = Set(posts.map { $0.uri })
            let newItems = fetched.filter { !existingURIs.contains($0.uri) }

            guard !newItems.isEmpty else { return (0, nil) }

            // Deduplicate thread context within the new batch, then re-run
            // deduplication across the seam between the new and existing posts
            // so a parent cell at the tail of the new batch isn't shown twice
            // if the first existing post is a reply to it.
            let deduped = Self.deduplicateThreadContext(newItems + posts)
            posts = deduped

            // Track the new posts as "unseen" — but only ones that survived
            // dedup and will actually render, or the rows could never
            // report themselves seen and the pill would stick.
            let renderedURIs = Set(deduped.map(\.uri))
            unseenNewPostURIs.formUnion(
                newItems.map(\.uri).filter { renderedURIs.contains($0) }
            )
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

    public func loadMore() async {
        guard hasMore, !isLoading, !isRefreshing, !isCheckingForNew, cursor != nil else { return }
        // Prevent concurrent loadMore calls from racing each other
        isLoading = true
        await fetch()
        isLoading = false
    }

    private func fetch(replacing: Bool = false) async {
        guard let kit = service.atProtoKit else { return }
        do {
            let output = try await kit.getTimeline(limit: 50, cursor: cursor)
            let newItems = output.feed.map { PostItem(feedPost: $0) }
            let dedupedItems = Self.deduplicateThreadContext(newItems)
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

    /// Removes posts that would appear redundantly as both a standalone feed cell AND
    /// as inline thread context above the reply that follows them.
    ///
    /// When the timeline contains post A immediately followed by post B (a direct reply
    /// to A), the feed cell fetches and shows A as a parent above B. Keeping A as its
    /// own cell too means the user sees it twice in a row.
    ///
    /// Rule: suppress post[i] if post[i+1].replyParentURI == post[i].uri.
    /// We only suppress the *immediately preceding* cell — not any further ancestors —
    /// so longer reply chains still show their own cells (they only inline up to 2 parents).
    /// Internal (not private) so the unit tests can exercise it directly.
    static func deduplicateThreadContext(_ items: [PostItem]) -> [PostItem] {
        guard items.count > 1 else { return items }
        var result: [PostItem] = []
        result.reserveCapacity(items.count)
        for (index, post) in items.enumerated() {
            // Check whether the *next* item in the feed is a direct reply to this post.
            // If so, skip this cell — the reply's thread context will show it inline.
            if index + 1 < items.count,
               items[index + 1].replyParentURI == post.uri {
                continue
            }
            result.append(post)
        }
        return result
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
