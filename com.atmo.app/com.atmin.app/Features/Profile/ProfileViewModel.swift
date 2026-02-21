import Foundation
import ATProtoKit
import Observation

@Observable
@MainActor
final class ProfileViewModel {

    private(set) var profile: ProfileModel? = nil
    private(set) var posts: [PostItem] = []
    private(set) var isLoading: Bool = false
    private(set) var isLoadingPosts: Bool = false
    private(set) var error: Error? = nil
    private var cursor: String? = nil
    private var hasMore: Bool = true

    private let service: ATProtoService
    let actorDID: String?

    /// Only refresh on new-post notification when viewing the current user's own profile.
    private var isOwnProfile: Bool {
        actorDID == nil || actorDID == service.currentUserDID
    }

    /// Retained so the notification observation lives as long as the ViewModel.
    /// `nonisolated(unsafe)` allows `deinit` (which is nonisolated) to cancel
    /// the task without a Swift 6 actor-isolation error, while all actual reads
    /// and writes happen on the MainActor.
    nonisolated(unsafe) private var postObservationTask: Task<Void, Never>? = nil

    init(service: ATProtoService, actorDID: String?) {
        self.service = service
        self.actorDID = actorDID
        // Schedule notification observation on the next run-loop tick so that
        // `self` is fully initialized before the task captures it. The task
        // body always runs on the MainActor, matching this class's isolation.
        Task { @MainActor [weak self] in
            self?.startObservingNewPosts()
        }
    }

    deinit {
        postObservationTask?.cancel()
    }

    // MARK: - New-post notification

    /// Listens for `atmoDidSubmitPost` and refreshes the author feed when it fires.
    /// Only responds when this ViewModel is showing the current user's own profile
    /// (i.e. the profile where the new post would appear).
    private func startObservingNewPosts() {
        // Use the raw notification name string to avoid crossing actor isolation
        // boundaries when accessing the Notification.Name extension.
        let notificationName = Notification.Name("com.atmo.app.didSubmitPost")
        postObservationTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: notificationName)
            for await _ in stream {
                guard let self, self.isOwnProfile else { continue }
                // Short delay so the server has time to index the new post
                // before we fetch the author feed.
                try? await Task.sleep(for: .seconds(1))
                await self.loadPosts(reset: true)
            }
        }
    }

    // MARK: - Loading

    func load() async {
        guard let kit = service.atProtoKit else { return }
        isLoading = true
        defer { isLoading = false }

        let identifier: String
        if let did = actorDID {
            identifier = did
        } else if let handle = service.currentHandle {
            identifier = handle
        } else {
            return
        }

        do {
            let output = try await kit.getProfile(for: identifier)
            profile = ProfileModel(profile: output)
            error = nil
        } catch {
            self.error = error
        }

        await loadPosts(reset: true)
    }

    func loadPosts(reset: Bool = false) async {
        guard let kit = service.atProtoKit else { return }
        if reset {
            cursor = nil
            posts = []
            hasMore = true
        }
        guard hasMore, !isLoadingPosts else { return }

        // getAuthorFeed requires a DID — handles are not accepted.
        // Prefer (in order):
        //   1. The DID we already resolved from getProfile (stored on profile.did)
        //   2. The DID passed into this ViewModel at init (for other users' profiles)
        //   3. The current user's DID from the session (own profile via sidebar)
        let did: String
        if let resolvedDID = profile?.did {
            did = resolvedDID
        } else if let initDID = actorDID {
            did = initDID
        } else if let sessionDID = service.currentUserDID {
            did = sessionDID
        } else {
            // DID not yet available — bail; load() will call loadPosts again after getProfile
            return
        }

        isLoadingPosts = true
        do {
            let output = try await kit.getAuthorFeed(by: did, limit: 30, cursor: cursor)
            let newPosts = output.feed.map { PostItem(feedPost: $0) }
            posts.append(contentsOf: newPosts)
            cursor = output.cursor
            hasMore = output.cursor != nil
        } catch {
            self.error = error
        }
        isLoadingPosts = false
    }

    // MARK: - Edit Profile

    /// Updates the current user's display name, bio, and optionally avatar.
    /// - Parameters:
    ///   - displayName: New display name (empty string clears it).
    ///   - description: New bio text (empty string clears it).
    ///   - avatarData: Raw JPEG data for a new avatar image, or nil to keep existing.
    func updateProfile(displayName: String, description: String, avatarData: Data?) async {
        guard let bluesky = service.atProtoBluesky,
              let did = service.currentUserDID else { return }

        let profileURI = "at://\(did)/app.bsky.actor.profile/self"

        var fields: [ATProtoBluesky.UpdatedProfileRecordField] = [
            .displayName(with: displayName.isEmpty ? nil : displayName),
            .description(with: description.isEmpty ? nil : description)
        ]

        if let data = avatarData {
            let imageQuery = ATProtoTools.ImageQuery(
                imageData: data,
                fileName: "avatar.jpg",
                altText: nil,
                aspectRatio: nil
            )
            fields.append(.avatarImage(with: imageQuery))
        }

        do {
            _ = try await bluesky.updateProfileRecord(profileURI: profileURI, replace: fields)
            // Refresh to reflect server-confirmed values (avatar URL may change)
            await load()
        } catch {
            self.error = error
        }
    }

    // MARK: - Follow / Unfollow

    func toggleFollow() async {
        guard let bluesky = service.atProtoBluesky,
              let profile = profile else { return }

        if profile.isFollowing {
            guard let followURI = profile.followURI else { return }
            self.profile?.isFollowing = false
            self.profile?.followURI = nil
            do {
                try await bluesky.deleteRecord(.recordURI(atURI: followURI))
            } catch {
                // Rollback
                self.profile?.isFollowing = true
                self.profile?.followURI = followURI
                self.error = error
            }
        } else {
            guard let targetDID = self.profile?.did else { return }
            self.profile?.isFollowing = true
            do {
                let result = try await bluesky.createFollowRecord(actorDID: targetDID)
                self.profile?.followURI = result.recordURI
            } catch {
                self.profile?.isFollowing = false
                self.profile?.followURI = nil
                self.error = error
            }
        }
    }
}
