import Foundation
import Testing
@testable import AtmoCore

@MainActor
struct NotificationSettingsTests {

    private func makeStore() -> NotificationSettingsStore {
        let suiteName = "atmo-notify-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return NotificationSettingsStore(defaults: defaults)
    }

    @Test func defaultsToAllReasonsButDisabledMaster() {
        let store = makeStore()
        #expect(!store.interactionsEnabled)
        for reason in NotificationSettingsStore.notifiableReasons {
            #expect(store.isReasonEnabled(reason))
        }
    }

    @Test func togglingReasonsPersistsInMemory() {
        let store = makeStore()
        store.setReason(.like, enabled: false)
        #expect(!store.isReasonEnabled(.like))
        #expect(store.isReasonEnabled(.reply))
        store.setReason(.like, enabled: true)
        #expect(store.isReasonEnabled(.like))
    }

    @Test func subscriptionLifecycle() {
        let store = makeStore()
        store.setSubscription(did: "did:a", handle: "alice.test", displayName: "Alice", mode: .allPosts)
        #expect(store.subscription(for: "did:a")?.mode == .allPosts)

        store.setSubscription(did: "did:a", handle: "alice.test", displayName: "Alice", mode: .originalPostsOnly)
        #expect(store.subscription(for: "did:a")?.mode == .originalPostsOnly)
        #expect(store.subscriptions.count == 1)

        // Off removes the subscription entirely.
        store.setSubscription(did: "did:a", handle: "alice.test", displayName: "Alice", mode: .off)
        #expect(store.subscription(for: "did:a") == nil)
        #expect(store.subscriptions.isEmpty)
    }
}

@MainActor
struct BackgroundSyncFilterTests {

    @Test func originalPostsOnlySkipsReposts() {
        let mark = Date(timeIntervalSinceNow: -3600)
        let original = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        let repost = PostItem(testURI: "at://did:b/app.bsky.feed.post/2", isRepost: true)

        let all = BackgroundSyncEngine.newPosts(in: [original, repost], mode: .allPosts, newerThan: mark)
        #expect(all.count == 2)

        let originals = BackgroundSyncEngine.newPosts(in: [original, repost], mode: .originalPostsOnly, newerThan: mark)
        #expect(originals.map(\.uri) == [original.uri])
    }

    @Test func watermarkFiltersOldPosts() {
        let mark = Date()
        let old = PostItem(testURI: "at://did:a/app.bsky.feed.post/1", indexedAt: mark.addingTimeInterval(-60))
        let fresh = PostItem(testURI: "at://did:a/app.bsky.feed.post/2", indexedAt: mark.addingTimeInterval(60))

        let result = BackgroundSyncEngine.newPosts(in: [old, fresh], mode: .allPosts, newerThan: mark)
        #expect(result.map(\.uri) == [fresh.uri])
    }

    @Test func offModeAlertsNothing() {
        let mark = Date(timeIntervalSinceNow: -3600)
        let post = PostItem(testURI: "at://did:a/app.bsky.feed.post/1")
        #expect(BackgroundSyncEngine.newPosts(in: [post], mode: .off, newerThan: mark).isEmpty)
    }
}
