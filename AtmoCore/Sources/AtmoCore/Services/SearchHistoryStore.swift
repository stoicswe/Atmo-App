import Foundation
import Observation

// MARK: - SearchHistoryStore
// Recent searches, offered as tappable suggestions above the search bar.
// Opt-in and off by default: nothing is recorded until the person turns
// it on in Settings, and turning it off wipes what was kept. Device-local
// (UserDefaults), newest first, deduplicated case-insensitively.
@Observable
@MainActor
public final class SearchHistoryStore {

    public static let shared = SearchHistoryStore()

    /// UserDefaults key for the opt-in switch.
    nonisolated public static let enabledKey = "atmo.search.historyEnabled"
    /// How many searches are kept.
    nonisolated public static let maxEntries = 20
    /// How many are offered above the search bar.
    nonisolated public static let suggestionCount = 3
    /// Queries shorter than this are noise (a single letter mid-typing).
    nonisolated public static let minimumLength = 2

    /// Newest first.
    public private(set) var entries: [String]
    public private(set) var isEnabled: Bool

    private let defaults: UserDefaults
    private let entriesKey = "atmo.search.history"

    /// Internal so tests can point the store at a scratch suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.entries = enabled ? (defaults.stringArray(forKey: "atmo.search.history") ?? []) : []
    }

    /// The few most recent searches, for the suggestion pills.
    public var recent: [String] {
        Array(entries.prefix(Self.suggestionCount))
    }

    /// Turning history off also forgets everything recorded so far.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { clear() }
    }

    /// Remembers a search the person actually ran (submitted, or picked a
    /// result for). No-op while history is off.
    public func record(_ query: String) {
        guard isEnabled else { return }
        let updated = Self.inserting(query, into: entries, cap: Self.maxEntries)
        guard updated != entries else { return }
        entries = updated
        persist()
    }

    public func remove(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        persist()
    }

    public func clear() {
        entries = []
        defaults.removeObject(forKey: entriesKey)
    }

    private func persist() {
        defaults.set(entries, forKey: entriesKey)
    }

    /// Pure insert: trims, drops too-short queries, moves a repeat to the
    /// front keeping the newest spelling, and caps the list. Unit-tested.
    public nonisolated static func inserting(_ query: String, into entries: [String], cap: Int) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return entries }
        var result = entries.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        result.insert(trimmed, at: 0)
        if result.count > cap { result = Array(result.prefix(cap)) }
        return result
    }
}
