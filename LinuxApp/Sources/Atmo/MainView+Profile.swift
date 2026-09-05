import Adwaita
import Foundation
import AtmoCore

extension MainView {

    struct ProfileSnapshot: Equatable {
        var did = ""
        var name = ""
        var handle = ""
        var bio = ""
        var avatarURL: URL? = nil
        var isVerified = false
        var followers = 0
        var following = 0
        var posts = 0
        var isFollowing = false
        var isFollowedBy = false
        var isMuted = false
        var isBlocking = false
        var isHidingReposts = false
        var isSelf = false
        var isLoading = false
        var isLoadingPosts = false
        var loadFailed = false
        var webURL: String? = nil
        var filter = ProfileFeedFilter.posts.rawValue
        var rows: [PostRowSnapshot] = []
    }

    struct FilterToggle: ToggleGroupItem {
        let id: String
        let icon: Icon?
        var showLabel: Bool { true }
    }

    var filterToggles: [FilterToggle] {
        ProfileFeedFilter.allCases.map { FilterToggle(id: $0.displayName, icon: nil) }
    }

    var ownProfileSnapshot: (name: String, avatarURL: URL?)? {
        _ = tick
        return onMain {
            guard let profile = AppSession.shared.profileSession(for: AppSession.ownProfileKey).profile.profile else { return nil }
            return (profile.displayName ?? profile.handle, profile.avatarURL)
        }
    }

    func profileSnapshot(key: String) -> ProfileSnapshot {
        _ = tick
        return onMain {
            AppSession.shared.syncProfileInteractions(for: key)
            let session = AppSession.shared.profileSession(for: key)
            var snapshot = ProfileSnapshot()
            snapshot.isLoading = session.profile.isLoading
            snapshot.isLoadingPosts = session.profile.isLoadingPosts
            snapshot.loadFailed = session.profile.error != nil && session.profile.profile == nil
            snapshot.filter = session.profile.selectedFilter.displayName
            snapshot.isSelf = key == AppSession.ownProfileKey
            if let profile = session.profile.profile {
                snapshot.did = profile.did
                snapshot.name = profile.displayName ?? profile.handle
                snapshot.handle = profile.handle
                snapshot.bio = profile.description ?? ""
                snapshot.avatarURL = profile.avatarURL
                snapshot.isVerified = profile.verification != nil
                snapshot.followers = profile.followersCount
                snapshot.following = profile.followsCount
                snapshot.posts = profile.postsCount
                snapshot.isFollowing = profile.isFollowing
                snapshot.isFollowedBy = profile.isFollowedBy
                snapshot.isMuted = profile.isMuted
                snapshot.isBlocking = profile.isBlocking
                snapshot.isHidingReposts = session.profile.isHidingReposts
                snapshot.webURL = profile.bskyWebURL?.absoluteString
            }
            let live = Dictionary(session.interactions.posts.map { ($0.uri, $0) }, uniquingKeysWith: { first, _ in first })
            snapshot.rows = session.profile.posts.map { PostRowSnapshot(post: live[$0.uri] ?? $0) }
            return snapshot
        }
    }

    // MARK: - Page

    /// A profile: the header (avatar, name, bio, counts, follow/menu), the
    /// Posts/Replies/Media/Videos filter, then the author feed. Shown as
    /// the Profile pane (own account) or pushed for anyone else.
    @ViewBuilder func profilePage(key: String, embedded: Bool) -> Body {
        let snapshot = profileSnapshot(key: key)
        if snapshot.handle.isEmpty {
            if snapshot.loadFailed {
                StatusPage("Couldn't load this profile", icon: .custom(name: "dialog-error-symbolic"), description: "Check your connection and try again.") {
                    Button("Try Again") { loadProfile(key: key) }
                        .pill()
                        .halign(.center)
                }
                .vexpand()
            } else {
                Spinner()
                    .vexpand()
                    .valign(.center)
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    profileHeader(snapshot, key: key)
                    Separator()
                    ToggleGroup(selection: profileFilterBinding(key: key, current: snapshot.filter), values: filterToggles)
                        .halign(.center)
                        .padding(8)
                    Separator()
                    if snapshot.rows.isEmpty {
                        if snapshot.isLoadingPosts {
                            Spinner()
                                .padding(24)
                        } else {
                            StatusPage("Nothing here yet", icon: .custom(name: "view-list-symbolic"), description: "")
                                .padding(12)
                        }
                    } else {
                        ForEach(snapshot.rows, id: \.id) { row in
                            postRow(row, actions: .profile(key: key))
                            Separator()
                        }
                        loadMoreFooter(visible: true, loading: snapshot.isLoadingPosts) {
                            runCore {
                                await AppSession.shared.profileSession(for: key).profile.loadPosts()
                                AppSession.shared.syncProfileInteractions(for: key)
                            }
                        }
                    }
                }
                .frame(maxWidth: 720)
            }
            .vexpand()
            .onBottomEdgeReached {
                guard infiniteScrollEnabled else { return }
                runCore {
                    await AppSession.shared.profileSession(for: key).profile.loadPosts()
                    AppSession.shared.syncProfileInteractions(for: key)
                }
            }
        }
    }

    @ViewBuilder func profileHeader(_ snapshot: ProfileSnapshot, key: String) -> Body {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                remoteAvatar(url: snapshot.avatarURL, name: snapshot.name, size: 88)
                    .valign(.start)
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(snapshot.name)
                            .ellipsize()
                            .style("title-2")
                            .halign(.start)
                        if snapshot.isVerified {
                            Symbol(icon: .custom(name: "atmo-verified-symbolic"))
                                .style("accent")
                                .tooltip("Verified")
                        }
                    }
                    .hexpand()
                    HStack(spacing: 6) {
                        Text("@\(snapshot.handle)")
                            .ellipsize()
                            .style("dim-label")
                            .halign(.start)
                        if snapshot.isFollowedBy && !snapshot.isSelf {
                            Text("Follows you")
                                .style("caption")
                                .style("dim-label")
                                .style("card")
                                .padding(4, .horizontal)
                        }
                    }
                    HStack(spacing: 14) {
                        profileStat(snapshot.posts, "posts")
                        profileStat(snapshot.followers, "followers")
                        profileStat(snapshot.following, "following")
                    }
                    .halign(.start)
                    .padding(4, .top)
                }
                .hexpand()
                VStack(spacing: 6) {
                    if snapshot.isSelf {
                        Button("Edit Profile") { beginEditProfile() }
                            .pill()
                    } else if snapshot.isBlocking {
                        Button("Blocked") { toggleBlock(key: key, blocking: true) }
                            .pill()
                            .style("destructive-action")
                    } else {
                        Button(snapshot.isFollowing ? "Following" : "Follow") { toggleFollow(key: key) }
                            .pill()
                            .style("suggested-action", active: !snapshot.isFollowing)
                    }
                    Button(icon: .custom(name: "view-more-symbolic")) { moreMenuURI = "profile:" + key }
                        .flat()
                        .tooltip("More")
                        .popover(visible: moreMenuBinding("profile:" + key)) {
                            profileMenu(snapshot, key: key)
                        }
                }
                .valign(.start)
            }
            if !snapshot.bio.isEmpty {
                richTextLabel(RichTextMarkup.markup(for: RichText.segments(text: snapshot.bio, facets: [])))
            }
        }
        .padding(14)
    }

    @ViewBuilder func profileStat(_ count: Int, _ label: String) -> Body {
        HStack(spacing: 4) {
            Text(compactCount(count))
                .style("heading")
            Text(label)
                .style("dim-label")
        }
    }

    func compactCount(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 10_000...: return "\(count / 1000)K"
        case 1_000...: return String(format: "%.1fK", Double(count) / 1000)
        default: return "\(count)"
        }
    }

    /// Copy link, search posts, hide reposts, mute, block — the macOS ···
    /// menu (reporting is tracked in PORTING.md).
    @ViewBuilder func profileMenu(_ snapshot: ProfileSnapshot, key: String) -> Body {
        VStack(spacing: 4) {
            if let webURL = snapshot.webURL {
                Button("Copy link to profile", icon: .custom(name: "edit-copy-symbolic")) {
                    moreMenuURI = nil
                    Desktop.copy(webURL)
                    showToast("Link copied")
                }
                .flat()
                .halign(.start)
                Button("Open in Browser", icon: .custom(name: "web-browser-symbolic")) {
                    moreMenuURI = nil
                    Desktop.open(webURL)
                }
                .flat()
                .halign(.start)
            }
            Button("Search posts", icon: .custom(name: "system-search-symbolic")) {
                moreMenuURI = nil
                openAuthorSearch(handle: snapshot.handle)
            }
            .flat()
            .halign(.start)
            if !snapshot.isSelf {
                Button(snapshot.isHidingReposts ? "Show reposts in feeds" : "Hide reposts in feeds", icon: .custom(name: "atmo-repost-symbolic")) {
                    moreMenuURI = nil
                    onMain { AppSession.shared.profileSession(for: key).profile.setHidingReposts(!snapshot.isHidingReposts) }
                    tick += 1
                }
                .flat()
                .halign(.start)
                Button(snapshot.isMuted ? "Unmute account" : "Mute account", icon: .custom(name: "audio-volume-muted-symbolic")) {
                    moreMenuURI = nil
                    runCore { await AppSession.shared.profileSession(for: key).profile.toggleMute() }
                }
                .flat()
                .halign(.start)
                Button(snapshot.isBlocking ? "Unblock account" : "Block account", icon: .custom(name: "action-unavailable-symbolic")) {
                    moreMenuURI = nil
                    toggleBlock(key: key, blocking: snapshot.isBlocking)
                }
                .flat()
                .halign(.start)
                .style("error", active: !snapshot.isBlocking)
            }
        }
        .padding(6)
    }

    func profileFilterBinding(key: String, current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { name in
                guard let filter = ProfileFeedFilter.allCases.first(where: { $0.displayName == name }) else { return }
                runCore {
                    await AppSession.shared.profileSession(for: key).profile.selectFilter(filter)
                    AppSession.shared.syncProfileInteractions(for: key)
                }
            }
        )
    }

    // MARK: - Actions

    func toggleFollow(key: String) {
        runCore { await AppSession.shared.profileSession(for: key).profile.toggleFollow() }
    }

    /// Blocking asks first; unblocking is immediate — same as macOS.
    func toggleBlock(key: String, blocking: Bool) {
        if blocking {
            runCore { await AppSession.shared.profileSession(for: key).profile.toggleBlock() }
        } else {
            blockConfirmKey = key
        }
    }

    var blockConfirmVisibleBinding: Binding<Bool> {
        Binding(get: { blockConfirmKey != nil }, set: { if !$0 { blockConfirmKey = nil } })
    }

    func confirmBlock() {
        guard let key = blockConfirmKey else { return }
        blockConfirmKey = nil
        runCore { await AppSession.shared.profileSession(for: key).profile.toggleBlock() }
    }

    // MARK: - Edit profile

    func beginEditProfile() {
        let snapshot = profileSnapshot(key: AppSession.ownProfileKey)
        editDisplayName = snapshot.name
        editBio = snapshot.bio
        editAvatarData = nil
        editProfileVisible = true
    }

    @ViewBuilder var editProfileContent: Body {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if let data = editAvatarData {
                    Picture(data: data)
                        .canShrink()
                        .contentFit(.cover)
                        .frame(maxHeight: 72)
                } else {
                    remoteAvatar(url: profileSnapshot(key: AppSession.ownProfileKey).avatarURL, name: editDisplayName, size: 72)
                }
                Button("Change Avatar…", icon: .custom(name: "image-x-generic-symbolic")) { editAvatarPicker.signal() }
                    .flat()
            }
            .halign(.center)
            Form {
                EntryRow("Display name", text: $editDisplayName)
            }
            Text("Bio")
                .style("caption-heading")
                .halign(.start)
            TextEditor(text: $editBio)
                .innerPadding(8)
                .frame(minHeight: 120)
                .style("card")
                .vexpand()
            HStack(spacing: 8) {
                Text("")
                    .hexpand()
                Button("Cancel") { editProfileVisible = false }
                Button("Save") { saveProfile() }
                    .style("suggested-action")
            }
        }
        .padding(12)
        .fileImporter(
            open: $editAvatarPicker,
            filters: [.extensions(["png", "jpg", "jpeg", "webp"], name: "Images")],
            title: "Choose Avatar",
            onOpen: { url in editAvatarData = try? Data(contentsOf: url) }
        )
    }

    func saveProfile() {
        let name = editDisplayName
        let bio = editBio
        let avatar = editAvatarData
        editProfileVisible = false
        runCore {
            var avatarData = avatar
            if let avatar {
                // Fit like a post image: the profile blob has the same cap.
                avatarData = try? await PixbufMediaProcessor().prepareImage(avatar).data
            }
            let profile = AppSession.shared.profileSession(for: AppSession.ownProfileKey).profile
            await profile.updateProfile(displayName: name, description: bio, avatarData: avatarData)
            if profile.error != nil {
                presentError("The profile couldn't be saved.")
            } else {
                showToast("Profile saved")
            }
        }
    }
}
