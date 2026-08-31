import Foundation
import ATProtoKit

// MARK: - BackgroundSyncEngine
// One battery-friendly "sync pass" that the platforms schedule through
// their energy-efficient mechanisms (BGAppRefreshTask on iOS,
// NSBackgroundActivityScheduler on macOS — both system-coalesced).
//
// A pass makes the minimum number of network requests:
//   • one listNotifications page for interactions on the user's content,
//   • one small getAuthorFeed page per subscribed account.
// High-water marks (persisted in UserDefaults) guarantee each event
// alerts at most once, across launches. The first pass after enabling
// only records the marks — no flood of historical notifications.
@MainActor
public final class BackgroundSyncEngine {

    private let service: ATProtoService
    private let settings: NotificationSettingsStore
    private let defaults: UserDefaults

    private let interactionMarkKey = "atmo.sync.lastInteractionAt"
    private func postMarkKey(_ did: String) -> String { "atmo.sync.lastPostAt.\(did)" }

    public init(
        service: ATProtoService,
        settings: NotificationSettingsStore,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.settings = settings
        self.defaults = defaults
    }

    /// Runs one sync pass and returns the alerts the platform should
    /// present. Safe to call from any scheduler; returns quickly when
    /// nothing is enabled.
    public func performSyncPass() async -> [FeedAlert] {
        guard service.isAuthenticated else { return [] }
        var alerts: [FeedAlert] = []
        alerts += await checkInteractions()
        alerts += await checkSubscribedUsers()
        return alerts
    }

    // MARK: - Interactions on the user's own content

    private func checkInteractions() async -> [FeedAlert] {
        guard settings.interactionsEnabled,
              !settings.enabledReasons.isEmpty,
              let kit = service.atProtoKit else { return [] }

        do {
            let output = try await kit.listNotifications(limit: 30)
            let items = output.notifications.map { NotificationItem(notification: $0) }
            guard let newest = items.map(\.indexedAt).max() else { return [] }

            let mark = defaults.object(forKey: interactionMarkKey) as? Date
            defaults.set(newest, forKey: interactionMarkKey)

            // First pass: only establish the high-water mark.
            guard let mark else { return [] }

            var fresh = items
                .filter { $0.indexedAt > mark }
                .filter { settings.enabledReasons.contains($0.reason.settingsKind.rawValue) }

            // Give like/repost alerts the text of the post that was liked
            // or reposted (replies/mentions/quotes already carry theirs).
            // One batched lookup; a fresh batch never exceeds one page.
            let subjectURIs = NotificationItem.unresolvedSubjectURIs(in: fresh)
            if !subjectURIs.isEmpty,
               let posts = try? await kit.getPosts(Array(subjectURIs.prefix(25))) {
                var texts: [String: String] = [:]
                for post in posts.posts {
                    if let record = post.record.getRecord(ofType: AppBskyLexicon.Feed.PostRecord.self) {
                        texts[post.uri] = record.text
                    }
                }
                fresh = NotificationItem.injectingSnippets(into: fresh, texts: texts)
            }

            return fresh.map { item in
                FeedAlert(
                    id: item.uri,
                    title: item.authorDisplayName ?? "@\(item.authorHandle)",
                    body: Self.alertBody(for: item.reason, snippet: item.contentSnippet),
                    kind: .interaction(item.reason)
                )
            }
        } catch {
            // Background pass — never surface errors; try again next time.
            return []
        }
    }

    /// "Liked your post: “snippet…”" — the action sentence, plus a short
    /// piece of the relevant content when there is one. Internal (not
    /// private) for unit tests.
    nonisolated static func alertBody(
        for reason: NotificationItem.NotificationReason,
        snippet: String?
    ) -> String {
        let action = reason.displayText.prefix(1).capitalized + reason.displayText.dropFirst()
        let trimmed = snippet?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return action }
        return "\(action): “\(String(trimmed.prefix(120)))”"
    }

    // MARK: - New posts from subscribed accounts

    private func checkSubscribedUsers() async -> [FeedAlert] {
        guard let kit = service.atProtoKit else { return [] }
        var alerts: [FeedAlert] = []

        for subscription in settings.subscriptions where subscription.mode != .off {
            do {
                let output = try await kit.getAuthorFeed(by: subscription.did, limit: 10)
                let posts = output.feed.map { PostItem(feedPost: $0) }
                guard let newest = posts.map(\.indexedAt).max() else { continue }

                let key = postMarkKey(subscription.did)
                let mark = defaults.object(forKey: key) as? Date
                defaults.set(newest, forKey: key)

                // First pass for this account: mark only.
                guard let mark else { continue }

                let fresh = Self.newPosts(in: posts, mode: subscription.mode, newerThan: mark)
                let author = subscription.displayName ?? "@\(subscription.handle)"
                alerts += fresh.map { post in
                    FeedAlert(
                        id: post.uri,
                        title: "New post from \(author)",
                        body: String(post.displayText.prefix(140)),
                        kind: .newPost(authorDID: subscription.did)
                    )
                }
            } catch {
                continue
            }
        }
        return alerts
    }

    /// Filters an author-feed page down to the posts that should alert
    /// under the given mode. Internal (not private) for unit tests.
    /// `originalPostsOnly` drops feed items with a repost reason — those
    /// are the account re-sharing someone else's post.
    static func newPosts(
        in posts: [PostItem],
        mode: UserPostNotificationMode,
        newerThan mark: Date
    ) -> [PostItem] {
        posts
            .filter { $0.indexedAt > mark }
            .filter { post in
                switch mode {
                case .off:               return false
                case .allPosts:          return true
                case .originalPostsOnly: return post.reason == nil
                }
            }
    }
}
