import Foundation
import ATProtoKit
import Observation

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
    private var isLoading = false

    private init() {}

    /// Best-effort parallel fetch of all four sections; each fails
    /// independently and silently (the section just stays empty).
    public func load(service: ATProtoService) async {
        guard !isLoading, let kit = service.atProtoKit else { return }
        isLoading = true
        defer { isLoading = false }

        // getTrends carries post counts, actor facepiles, and hot status —
        // what the official Explore shows; getTrendingTopics still supplies
        // the evergreen "interests" list.
        async let trendsResult = try? kit.getTrends(limit: 8)
        async let topicsResult = try? kit.getTrendingTopics(limit: 8)
        async let feedsResult = try? kit.getSuggestedFeeds(limit: 8)
        async let actorsResult = try? kit.getSuggestions(limit: 8)

        if let trends = await trendsResult {
            trendingTopics = trends.trends.map { trend in
                TrendingTopicItem(
                    topic: trend.topic,
                    displayName: trend.displayName,
                    description: nil,
                    postCount: trend.postCount,
                    actorAvatarURLs: trend.actors.prefix(3).compactMap(\.avatarImageURL),
                    isHot: trend.status == .hot
                )
            }
        }
        if let topics = await topicsResult {
            // Fallback when getTrends failed (older AppViews).
            if trendingTopics.isEmpty {
                trendingTopics = topics.topics.map {
                    TrendingTopicItem(topic: $0.topic, displayName: $0.displayName, description: $0.description)
                }
            }
            suggestedTopics = topics.suggestedTopics.map {
                TrendingTopicItem(topic: $0.topic, displayName: $0.displayName, description: $0.description)
            }
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
}
