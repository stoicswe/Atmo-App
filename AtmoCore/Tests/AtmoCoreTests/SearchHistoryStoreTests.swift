import Foundation
import Testing
@testable import AtmoCore

@MainActor
struct SearchHistoryStoreTests {

    private func makeStore(suite: String = "atmo-search-history-\(UUID().uuidString)") -> (SearchHistoryStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        return (SearchHistoryStore(defaults: defaults), defaults)
    }

    @Test func offByDefaultAndRecordsNothingWhileOff() {
        let (store, _) = makeStore()
        #expect(!store.isEnabled)
        store.record("cats")
        #expect(store.entries.isEmpty)
        #expect(store.recent.isEmpty)
    }

    @Test func recordsNewestFirstDedupedAndPersists() {
        let (store, defaults) = makeStore()
        store.setEnabled(true)
        store.record("cats")
        store.record("dogs")
        store.record("Cats")          // repeat: moves to front, newest spelling wins
        store.record(" birds ")       // trimmed
        store.record("x")             // too short: ignored
        #expect(store.entries == ["birds", "Cats", "dogs"])
        #expect(store.recent == ["birds", "Cats", "dogs"])

        let reloaded = SearchHistoryStore(defaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(reloaded.entries == ["birds", "Cats", "dogs"])
    }

    @Test func recentIsCappedToThreeAndListToMax() {
        let (store, _) = makeStore()
        store.setEnabled(true)
        for i in 0..<(SearchHistoryStore.maxEntries + 5) {
            store.record("query \(i)")
        }
        #expect(store.entries.count == SearchHistoryStore.maxEntries)
        #expect(store.entries.first == "query \(SearchHistoryStore.maxEntries + 4)")
        #expect(store.recent.count == SearchHistoryStore.suggestionCount)
    }

    @Test func removeAndClear() {
        let (store, _) = makeStore()
        store.setEnabled(true)
        store.record("cats")
        store.record("dogs")
        store.remove("CATS")
        #expect(store.entries == ["dogs"])
        store.clear()
        #expect(store.entries.isEmpty)
    }

    @Test func turningOffForgetsHistory() {
        let (store, defaults) = makeStore()
        store.setEnabled(true)
        store.record("cats")
        store.setEnabled(false)
        #expect(store.entries.isEmpty)
        #expect(!SearchHistoryStore(defaults: defaults).isEnabled)
        #expect(SearchHistoryStore(defaults: defaults).entries.isEmpty)
    }

    @Test func pureInsertIsCaseInsensitiveAndCapped() {
        let base = ["bb", "aa"]
        #expect(SearchHistoryStore.inserting("AA", into: base, cap: 5) == ["AA", "bb"])
        #expect(SearchHistoryStore.inserting("cc", into: base, cap: 2) == ["cc", "bb"])
        #expect(SearchHistoryStore.inserting("  ", into: base, cap: 5) == base)
        #expect(SearchHistoryStore.inserting("x", into: base, cap: 5) == base)   // below minimum length
    }
}
