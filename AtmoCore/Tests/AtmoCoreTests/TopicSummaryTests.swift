import Foundation
import Testing
@testable import AtmoCore

/// Covers the AI topic-summary cache (3-day freshness, case-insensitive
/// topics, persistence).
@MainActor
struct TopicSummaryTests {

    private func freshStore(_ name: String = UUID().uuidString) -> (TopicSummaryStore, UserDefaults) {
        let suite = UserDefaults(suiteName: "test.summary.\(name)")!
        suite.removePersistentDomain(forName: "test.summary.\(name)")
        return (TopicSummaryStore(defaults: suite), suite)
    }

    @Test func freshWithinThreeDaysStaleAfter() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(TopicSummaryStore.isFresh(now.addingTimeInterval(-2 * 24 * 3600), now: now))
        #expect(!TopicSummaryStore.isFresh(now.addingTimeInterval(-3 * 24 * 3600 - 1), now: now))
    }

    @Test func topicsAreCaseInsensitive() {
        let (store, _) = freshStore()
        store.save(topic: "US Food Recalls", text: "A summary.")
        let hit = store.summary(for: "us food recalls")
        #expect(hit?.text == "A summary.")
        #expect(hit?.isFresh == true)
    }

    @Test func staleEntriesStillReturnWithFreshnessFlag() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (store, _) = freshStore()
        store.save(topic: "old", text: "Aged summary.", now: now.addingTimeInterval(-4 * 24 * 3600))
        let hit = store.summary(for: "old", now: now)
        #expect(hit?.text == "Aged summary.")
        #expect(hit?.isFresh == false)
    }

    @Test func persistsAcrossRelaunch() {
        let name = UUID().uuidString
        let (store, suite) = freshStore(name)
        store.save(topic: "topic", text: "Persisted.")
        let reloaded = TopicSummaryStore(defaults: suite)
        #expect(reloaded.summary(for: "topic")?.text == "Persisted.")
    }

    // MARK: - Verified-first sampling

    @Test func verifiedAuthorsLeadTheSampleKeepingOrder() {
        let posts = [
            PostItem(testURI: "p1", text: "a"),
            PostItem(testURI: "p2", text: "b", authorVerification: .verified),
            PostItem(testURI: "p3", text: "c"),
            PostItem(testURI: "p4", text: "d", authorVerification: .trustedVerifier),
            PostItem(testURI: "p5", text: "e")
        ]
        let sample = TopicSummaryStore.prioritizedSample(posts)
        #expect(sample.map(\.uri) == ["p2", "p4", "p1", "p3", "p5"])
    }

    @Test func sampleIsCappedAfterPrioritizing() {
        let unverified = (0..<30).map { PostItem(testURI: "u\($0)") }
        let verified = PostItem(testURI: "v", authorVerification: .verified)
        let sample = TopicSummaryStore.prioritizedSample(unverified + [verified], limit: 25)
        #expect(sample.count == 25)
        // The verified post makes the cut even from the very back of the list.
        #expect(sample.first?.uri == "v")
    }
}
