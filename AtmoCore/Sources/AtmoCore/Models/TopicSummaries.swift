import Foundation

// MARK: - Topic Summaries
/// Cache for on-device AI topic summaries: one entry per topic, fresh for
/// three days. Generation itself lives in the platform layer (Apple
/// Intelligence); this store only remembers results.
@MainActor
public final class TopicSummaryStore {

    public static let shared = TopicSummaryStore()

    /// How long a summary stays fresh.
    nonisolated public static let timeToLive: TimeInterval = 3 * 24 * 3600
    /// Settings toggle key. OFF by default — summaries are opt-in.
    nonisolated public static let enabledKey = "atmo.ai.topicSummariesEnabled"
    nonisolated private static let cacheKey = "atmo.ai.topicSummaries.cache"
    /// Oldest entries are pruned beyond this count.
    nonisolated private static let capacity = 50

    /// Orders posts for the summary prompt: posts from verified accounts
    /// (and trusted verifiers) first, each group keeping its original
    /// ranking, then capped to `limit`. The model's sample is small, so
    /// leaning it toward higher-trust sources produces better summaries.
    nonisolated public static func prioritizedSample(
        _ posts: [PostItem],
        limit: Int = 25
    ) -> [PostItem] {
        let verified = posts.filter { $0.authorVerification != nil }
        let unverified = posts.filter { $0.authorVerification == nil }
        return Array((verified + unverified).prefix(limit))
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let text: String
        public let date: Date
        public init(text: String, date: Date) {
            self.text = text
            self.date = date
        }
    }

    private var entries: [String: Entry]
    private let defaults: UserDefaults

    /// Internal so tests can run against an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    nonisolated public static func isFresh(_ date: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(date) < timeToLive
    }

    /// The cached summary for a topic (case-insensitive), if any, with
    /// its freshness.
    public func summary(for topic: String, now: Date = Date()) -> (text: String, isFresh: Bool)? {
        guard let entry = entries[Self.key(topic)] else { return nil }
        return (entry.text, Self.isFresh(entry.date, now: now))
    }

    public func save(topic: String, text: String, now: Date = Date()) {
        entries[Self.key(topic)] = Entry(text: text, date: now)
        // Prune oldest beyond capacity.
        if entries.count > Self.capacity {
            let sorted = entries.sorted { $0.value.date < $1.value.date }
            for (key, _) in sorted.prefix(entries.count - Self.capacity) {
                entries.removeValue(forKey: key)
            }
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    nonisolated private static func key(_ topic: String) -> String {
        topic.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
