import Foundation
import ATProtoKit

/// Local model wrapping ATProtoKit's profile types.
struct ProfileModel: Identifiable, Hashable {
    let id: String          // == actorDID
    let did: String
    let handle: String
    let displayName: String?
    let description: String?
    let avatarURL: URL?
    let bannerURL: URL?

    // Stats
    let followersCount: Int
    let followsCount: Int
    let postsCount: Int

    // Viewer state
    var isFollowing: Bool
    var isFollowedBy: Bool
    var followURI: String?

    // MARK: - Init from detailed profile
    init(profile: AppBskyLexicon.Actor.ProfileViewDetailedDefinition) {
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
    }

    // MARK: - Init from search result (ProfileViewDefinition — lighter type returned by searchActors)
    init(searchResult: AppBskyLexicon.Actor.ProfileViewDefinition) {
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
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ProfileModel, rhs: ProfileModel) -> Bool {
        lhs.id == rhs.id
    }
}
