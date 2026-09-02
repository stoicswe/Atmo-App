import Foundation
import Testing
@testable import AtmoCore

/// Ghost Posts: the marker, the 24-hour clock, the store's due/merge rules,
/// and the badge text.
struct GhostPostTests {

    @Test func markerAndClock() {
        #expect(GhostPostPolicy.isGhost(labels: ["atmo-ghost"]))
        #expect(GhostPostPolicy.isGhost(labels: ["porn", "atmo-ghost"]))
        #expect(!GhostPostPolicy.isGhost(labels: []))
        #expect(!GhostPostPolicy.isGhost(labels: ["ghost"]))
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(GhostPostPolicy.expiresAt(createdAt: created) == created.addingTimeInterval(GhostPostPolicy.lifetime))
    }

    @Test func remainingText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(GhostPostPolicy.remainingText(until: now.addingTimeInterval(5 * 3600 + 10), now: now) == "5h left")
        #expect(GhostPostPolicy.remainingText(until: now.addingTimeInterval(40 * 60), now: now) == "40m left")
        #expect(GhostPostPolicy.remainingText(until: now.addingTimeInterval(30), now: now) == "ending soon")
        #expect(GhostPostPolicy.remainingText(until: now.addingTimeInterval(-30), now: now) == "ending soon")
    }

    @Test func dueAndMerge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = GhostPostEntry(uri: "at://p/1", text: "a", createdAt: now.addingTimeInterval(-25 * 3600), expiresAt: now.addingTimeInterval(-3600))
        let fresh = GhostPostEntry(uri: "at://p/2", text: "b", createdAt: now.addingTimeInterval(-3600), expiresAt: now.addingTimeInterval(23 * 3600))
        #expect(GhostPostStore.due(in: [old, fresh], now: now).map(\.uri) == ["at://p/1"])
        // Union by URI, newest first, no duplicates.
        let merged = GhostPostStore.merged([old], [fresh, old])
        #expect(merged.map(\.uri) == ["at://p/2", "at://p/1"])
        #expect(GhostPostStore.isAlreadyGone(NSError(domain: "x", code: 404, userInfo: [NSLocalizedDescriptionKey: "Record not found"])))
        #expect(!GhostPostStore.isAlreadyGone(NSError(domain: "x", code: 0, userInfo: [NSLocalizedDescriptionKey: "network down"])))
    }

    @Test @MainActor func storeRecordsAndPersists() {
        let defaults = UserDefaults(suiteName: "atmo-ghost-\(UUID().uuidString)")!
        let kvs = GhostMemoryStore()
        let store = GhostPostStore(defaults: defaults, syncedStore: kvs)
        store.record(uri: "at://p/1", text: "hello", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(store.isGhost(uri: "at://p/1"))
        #expect(store.active.first?.expiresAt == Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(GhostPostPolicy.lifetime))
        let reloaded = GhostPostStore(defaults: UserDefaults(suiteName: "atmo-ghost-\(UUID().uuidString)")!, syncedStore: kvs)
        #expect(reloaded.active.map(\.uri) == ["at://p/1"])
    }
}

private final class GhostMemoryStore: SyncedKeyValueStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func string(forKey key: String) -> String? { storage[key].flatMap { String(data: $0, encoding: .utf8) } }
    func set(_ data: Data, forKey key: String) { storage[key] = data }
    func set(_ string: String, forKey key: String) { storage[key] = Data(string.utf8) }
    func removeValue(forKey key: String) { storage[key] = nil }
    func synchronize() {}
    func externalChanges() -> AsyncStream<[String]> { AsyncStream { $0.finish() } }
}
