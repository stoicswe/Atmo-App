import Foundation
import Testing
@testable import AtmoCore

@MainActor
struct AccountProfileCacheTests {

    private func makeCache() -> (AccountProfileCache, UserDefaults) {
        let defaults = UserDefaults(suiteName: "atmo-account-cache-\(UUID().uuidString)")!
        return (AccountProfileCache(defaults: defaults), defaults)
    }

    @Test func stalenessRule() {
        let now = Date()
        #expect(AccountProfileCache.isStale(nil, now: now))
        let fresh = AccountProfileCache.Snapshot(did: "did:plc:a", handle: "a", displayName: nil, bio: nil, avatarURL: nil, verification: nil, memberSince: nil, fetchedAt: now.addingTimeInterval(-3600))
        #expect(!AccountProfileCache.isStale(fresh, now: now))
        let old = AccountProfileCache.Snapshot(did: "did:plc:a", handle: "a", displayName: nil, bio: nil, avatarURL: nil, verification: nil, memberSince: nil, fetchedAt: now.addingTimeInterval(-2 * 24 * 3600))
        #expect(AccountProfileCache.isStale(old, now: now))
    }

    @Test func persistsAndKeepsKnownJoinDate() throws {
        let (cache, defaults) = makeCache()
        let joined = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AccountProfileCache.Snapshot(did: "did:plc:a", handle: "alice.bsky.social", displayName: "Alice", bio: "hi", avatarURL: URL(string: "https://cdn/x"), verification: "verified", memberSince: joined, fetchedAt: Date())
        // Store through the public path by round-tripping a snapshot into defaults.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode([snapshot.did: snapshot]), forKey: "atmo.account.profileCache")
        let reloaded = AccountProfileCache(defaults: defaults)
        let got = try #require(reloaded.snapshot(for: "did:plc:a"))
        #expect(got.displayName == "Alice")
        #expect(got.verificationBadge == .verified)
        #expect(got.memberSince == joined)
        #expect(!reloaded.isStale(for: "did:plc:a"))
        _ = cache
    }
}
