import Foundation
import ATProtoKit

/// Local model wrapping ATProtoKit's profile types.
public struct ProfileModel: Identifiable, Hashable, Sendable {
    public let id: String          // == actorDID
    public let did: String
    public let handle: String
    public let displayName: String?
    public let description: String?
    public let avatarURL: URL?
    public let bannerURL: URL?

    // Stats
    public let followersCount: Int
    public let followsCount: Int
    public let postsCount: Int

    // Viewer state
    public var isFollowing: Bool
    public var isFollowedBy: Bool
    public var followURI: String?
    /// Bluesky verification badge, when valid.
    public var verification: VerificationBadge? = nil

    // MARK: - Init from detailed profile
    public init(profile: AppBskyLexicon.Actor.ProfileViewDetailedDefinition) {
        self.did = profile.actorDID
        self.id = profile.actorDID
        self.handle = profile.actorHandle
        self.displayName = profile.displayName
        self.description = profile.description
        self.avatarURL = profile.avatarImageURL
        self.bannerURL = profile.bannerImageURL
        self.followersCount = profile.followerCount ?? 0
        self.followsCount = profile.followCount ?? 0
        self.postsCount = profile.postCount ?? 0
        self.isFollowing = profile.viewer?.followingURI != nil
        self.followURI = profile.viewer?.followingURI
        self.isFollowedBy = profile.viewer?.followedByURI != nil
        self.verification = VerificationBadge(state: profile.verificationState)
    }

    // MARK: - Init from search result (ProfileViewDefinition — lighter type returned by searchActors)
    public init(searchResult: AppBskyLexicon.Actor.ProfileViewDefinition) {
        self.did = searchResult.actorDID
        self.id = searchResult.actorDID
        self.handle = searchResult.actorHandle
        self.displayName = searchResult.displayName
        self.description = searchResult.description
        self.avatarURL = searchResult.avatarImageURL
        self.bannerURL = nil
        self.followersCount = 0
        self.followsCount = 0
        self.postsCount = 0
        self.isFollowing = searchResult.viewer?.followingURI != nil
        self.followURI = searchResult.viewer?.followingURI
        self.isFollowedBy = searchResult.viewer?.followedByURI != nil
        self.verification = VerificationBadge(state: searchResult.verificationState)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: ProfileModel, rhs: ProfileModel) -> Bool {
        lhs.id == rhs.id
    }
}
