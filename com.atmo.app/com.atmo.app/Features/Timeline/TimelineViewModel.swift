import Foundation
import ATProtoKit
import Observation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Refresh interval constants
// macOS users are typically plugged in and expect fresher content.
// iOS respects battery by refreshing less aggressively.
private extension TimeInterval {
#if os(macOS)
    static let periodicRefreshInterval: TimeInterval = 60        // 1 minute on macOS
#else
    static let periodicRefreshInterval: TimeInterval = 3 * 60    // 3 minutes on iOS/iPadOS
#endif
}

@Observable
@MainActor
final class TimelineViewModel {

    private(set) var posts: [PostItem] = []
    private(set) var isLoading: Bool = false
    private(set) var isRefreshing: Bool = false
    /// Number of new posts silently prepended at the top (drives the "new posts" pill)
    private(set) var newPostsCount: Int = 0
    /// Unique authors of the new posts, in the order they were prepended (newest first).
    /// Used by NewPostsPill to show avatar stacks. Capped at 4 for display purposes.
    private(set) var newPostAuthors: [PostItem] = []
    /// The URI of the first post that existed *before* the most recent silent prepend.
    /// The view should immediately (no animation) scroll to this URI after new posts are
    /// prepended so the existing content doesn't visually jump upward.
    private(set) var newPostsAnchorURI: String? = nil
    private(set) var error: Error? = nil
    private var cursor: String? = nil
    private var hasMore: Bool = true
    /// Guards against concurrent checkForNewPosts calls (e.g. rapid onAppear firings)
    private var isCheckingForNew: Bool = false

    private let service: ATProtoService

    /// Retained background task that sleeps between periodic silent refresh ticks.
    /// `nonisolated(unsafe)` allows `deinit` (which is nonisolated in Swift 6) to
    /// cancel the task without an actor-isolation error. All reads/writes happen on
    /// the MainActor via the `@MainActor`-isolated methods that set these properties.
    nonisolated(unsafe) private var refreshTimerTask: Task<Void, Never>? = nil
    /// Retained task that listens for foreground-resume notifications.
    nonisolated(unsafe) private var sceneObservationTask: Task<Void, Never>? = nil

    init(service: ATProtoService) {
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
    }

    // MARK: - Periodic Background Refresh

    /// Starts a looping background task that silently checks for new posts on an
    /// interval appropriate for the current platform. The task respects any
    /// in-flight loading operations (guarded by checkForNewPosts's own guards).
    private func startPeriodicRefresh() {
        refreshTimerTask = Task { [weak self] in
            // Wait one interval before the first tick so we don't double-fetch
            // on launch (loadInitial already runs at startup).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(.periodicRefreshInterval))
                guard !Task.isCancelled else { break }
                await self?.checkForNewPosts()
            }
        }
    }

    /// Listens for `scenePhase` active transitions (app returning to foreground)
    /// via `UIApplication.didBecomeActiveNotification` / `NSApplication.didBecomeActiveNotification`
    /// and triggers a silent check immediately when the app is foregrounded.
    private func startSceneObservation() {
#if os(iOS)
        let notificationName = UIApplication.didBecomeActiveNotification
#else
        let notificationName = NSApplication.didBecomeActiveNotification
#endif
        sceneObservationTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: notificationName)
            for await _ in stream {
                guard !Task.isCancelled else { break }
                await self?.checkForNewPosts()
            }
        }
    }

    // MARK: - Loading

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        cursor = nil
        posts = []
        hasMore = true
        await fetch()
        isLoading = false
    }

    func refresh() async {
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
    func checkForNewPosts() async -> (count: Int, anchorURI: String?) {
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
            newPostsCount = newItems.count
            newPostsAnchorURI = anchorURI

            // Build a deduplicated author list for the pill avatar stack.
            // Walk new items newest-first, collect up to 4 unique authors.
            var seenDIDs = Set<String>()
            var authors: [PostItem] = []
            for item in newItems {
                let did = item.authorDID
                if seenDIDs.insert(did).inserted {
                    authors.append(item)
                    if authors.count == 4 { break }
                }
            }
            newPostAuthors = authors

            return (newItems.count, anchorURI)
        } catch {
            // Silent failure — not worth surfacing an error for a background check
            return (0, nil)
        }
    }

    /// Called after the user acknowledges the new-posts pill (taps it or pull-refreshes).
    func clearNewPostsCount() {
        newPostsCount = 0
        newPostAuthors = []
        newPostsAnchorURI = nil
    }

    func loadMore() async {
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
    /// to A), `FeedItemView` / `ThreadContextView` fetches and shows A as a parent
    /// above B. Keeping A as its own cell too means the user sees it twice in a row.
    ///
    /// Rule: suppress post[i] if post[i+1].replyParentURI == post[i].uri.
    /// We only suppress the *immediately preceding* cell — not any further ancestors —
    /// so longer reply chains still show their own cells (they only inline up to 2 parents).
    private static func deduplicateThreadContext(_ items: [PostItem]) -> [PostItem] {
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
    func seedPosts(_ items: [PostItem]) {
        posts = items
    }

    // MARK: - Quote

    /// Called after the user successfully submits a quote post.
    /// Marks the original post as quoted in the local list so the repost button
    /// immediately reflects the action — the API has no viewer.isQuoted field.
    func markAsQuoted(post: PostItem) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[index].isQuoted = true
        posts[index].quoteCount += 1
    }

    // MARK: - Like

    func toggleLike(post: PostItem) async {
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

    func toggleRepost(post: PostItem) async {
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
