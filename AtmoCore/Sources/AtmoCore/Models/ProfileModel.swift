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
    /// The viewer has muted this account (server-side mute).
    public var isMuted: Bool = false
    /// URI of the viewer's block record against this account, when blocking.
    public var blockURI: String? = nil
    /// This account has blocked the viewer.
    public var isBlockedBy: Bool = false
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
        self.isMuted = profile.viewer?.isMuted ?? false
        self.blockURI = profile.viewer?.blockingURI
        self.isBlockedBy = profile.viewer?.isBlocked ?? false
        self.verification = VerificationBadge(state: profile.verificationState)
    }

    /// The viewer is blocking this account.
    public var isBlocking: Bool { blockURI != nil }

    /// Canonical Bluesky web URL for the profile (`https://bsky.app/profile/{handle}`),
    /// used by "Copy link to profile" and share sheets.
    public var bskyWebURL: URL? {
        URL(string: "https://bsky.app/profile/\(handle)")
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
        self.isMuted = searchResult.viewer?.isMuted ?? false
        self.blockURI = searchResult.viewer?.blockingURI
        self.isBlockedBy = searchResult.viewer?.isBlocked ?? false
        self.verification = VerificationBadge(state: searchResult.verificationState)
    }

    // Equality is synthesized memberwise — deliberately. An identity-only
    // `==` (just the DID) made a follow-state flip compare EQUAL to the
    // old value, so SwiftUI skipped re-rendering the profile header and
    // the Follow button froze even though the server calls succeeded.
}
