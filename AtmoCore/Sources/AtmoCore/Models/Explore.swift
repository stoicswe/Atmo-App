import Foundation
import ATProtoKit
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Explore Models
/// One trending or suggested topic from Bluesky's Explore surface.
public struct TrendingTopicItem: Identifiable, Sendable, Hashable {
    public let id: String   // == topic
    public let topic: String
    public let displayName: String
    public let description: String?
    /// How many posts the trend spans (nil for interests, which have none).
    public let postCount: Int?
    /// Avatars of accounts posting about the trend (facepile).
    public let actorAvatarURLs: [URL]
    /// Bluesky marked the trend as hot.
    public let isHot: Bool

    public init(
        topic: String,
        displayName: String?,
        description: String?,
        postCount: Int? = nil,
        actorAvatarURLs: [URL] = [],
        isHot: Bool = false
    ) {
        self.id = topic
        self.topic = topic
        self.displayName = displayName?.isEmpty == false ? displayName! : topic
        self.description = description
        self.postCount = postCount
        self.actorAvatarURLs = actorAvatarURLs
        self.isHot = isHot
    }
}

/// One account from Bluesky's suggested-accounts surface.
public struct SuggestedAccountItem: Identifiable, Sendable, Hashable {
    public let id: String   // == did
    public let did: String
    public let handle: String
    public let displayName: String?
    public let avatarURL: URL?
    public let description: String?

    public init(did: String, handle: String, displayName: String?, avatarURL: URL?, description: String?) {
        self.id = did
        self.did = did
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.description = description
    }
}

// MARK: - Explore Store
/// Session cache of Bluesky's algorithmic Explore content: trending
/// topics, suggested topics (interests), discover feeds, and suggested
/// accounts. Everything here comes from Bluesky's own suggestion
/// endpoints — the app adds nothing of its own — and the Search page only
/// shows it when the explore-suggestions control allows it.
@Observable
@MainActor
public final class ExploreStore {

    public static let shared = ExploreStore()

    public private(set) var trendingTopics: [TrendingTopicItem] = []
    /// "Interests" — evergreen suggested topics, distinct from trending.
    public private(set) var suggestedTopics: [TrendingTopicItem] = []
    public private(set) var suggestedFeeds: [CustomFeedItem] = []
    public private(set) var suggestedAccounts: [SuggestedAccountItem] = []
    public private(set) var hasLoadedOnce = false

    private init() {}

    /// Best-effort parallel fetch of all four sections; each fails
    /// independently and silently (the section just stays empty).
    ///
    /// Trends and topics come straight from the PUBLIC AppView with
    /// tolerant decoding — the live `getTrends` payload carries status
    /// values ("trending") the typed lexicon rejects, and public access
    /// means these sections work even before the session restores.
    /// Suggested feeds/accounts are personalized and need the session.
    /// (No in-flight guard — same `.task(id:)` cancel-and-replace
    /// rationale as `SavedFeedsStore.load`.)
    public func load(service: ATProtoService) async {
        async let trendsResult = Self.fetchPublicTrends(limit: 8)
        async let topicsResult = Self.fetchPublicTopics(limit: 8)

        let kit = service.atProtoKit
        async let feedsResult = kit.map { k in Task { try? await k.getSuggestedFeeds(limit: 8) } }?.value
        async let actorsResult = kit.map { k in Task { try? await k.getSuggestions(limit: 8) } }?.value

        if let trends = await trendsResult, !trends.isEmpty {
            trendingTopics = trends
        }
        if let topics = await topicsResult {
            if trendingTopics.isEmpty {
                trendingTopics = topics.topics
            }
            suggestedTopics = topics.suggested
        }
        if let feeds = await feedsResult {
            suggestedFeeds = feeds.feeds.map {
                CustomFeedItem(
                    uri: $0.feedURI,
                    displayName: $0.displayName,
                    avatarURL: $0.avatarImageURL,
                    isPinned: false
                )
            }
        }
        if let actors = await actorsResult {
            suggestedAccounts = actors.actors.map {
                SuggestedAccountItem(
                    did: $0.actorDID,
                    handle: $0.actorHandle,
                    displayName: $0.displayName,
                    avatarURL: $0.avatarImageURL,
                    description: $0.description
                )
            }
        }
        hasLoadedOnce = true
    }

    // MARK: Public AppView fetches (tolerant decoding)

    private struct PublicTrend: Decodable {
        let topic: String
        let displayName: String?
        let description: String?
        let postCount: Int?
        let status: String?
        let actors: [PublicActor]?
        struct PublicActor: Decodable {
            let avatar: String?
        }
    }

    nonisolated private static func fetchPublicTrends(limit: Int) async -> [TrendingTopicItem]? {
        struct Response: Decodable { let trends: [PublicTrend] }
        guard let url = URL(string: "https://public.api.bsky.app/xrpc/app.bsky.unspecced.getTrends?limit=\(limit)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return decoded.trends.map { trend in
            // getTrends' `topic` is an opaque feed key ("1ddc5211b77e"),
            // not a searchable term — the human phrase lives in
            // displayName, and that's what a tap should search for.
            let searchTerm = trend.displayName?.isEmpty == false ? trend.displayName! : trend.topic
            return TrendingTopicItem(
                topic: searchTerm,
                displayName: trend.displayName,
                description: trend.description,
                postCount: trend.postCount,
                actorAvatarURLs: (trend.actors ?? []).prefix(3).compactMap { $0.avatar.flatMap(URL.init(string:)) },
                isHot: trend.status == "hot"
            )
        }
    }

    nonisolated private static func fetchPublicTopics(limit: Int) async -> (topics: [TrendingTopicItem], suggested: [TrendingTopicItem])? {
        struct Topic: Decodable {
            let topic: String
            let displayName: String?
            let description: String?
        }
        struct Response: Decodable {
            let topics: [Topic]
            let suggested: [Topic]?
        }
        guard let url = URL(string: "https://public.api.bsky.app/xrpc/app.bsky.unspecced.getTrendingTopics?limit=\(limit)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        let map = { (t: Topic) in TrendingTopicItem(topic: t.topic, displayName: t.displayName, description: t.description) }
        return (decoded.topics.map(map), (decoded.suggested ?? []).map(map))
    }
}
