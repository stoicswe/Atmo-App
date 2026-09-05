import Adwaita
import CAdw
import Foundation
import AtmoCore

/// The window shell. Before sign-in: a login page. After: an
/// `AdwNavigationSplitView` — a sidebar listing the same destinations as
/// the macOS sidebar (Home + pinned feeds, Search, Activity, Messages,
/// Profile; Library: Bookmarks, Liked, Drafts, Ghosts, Settings; saved
/// feeds) — with the selected pane on the content side, where thread,
/// profile, and conversation pages push onto an `AdwNavigationView`.
/// See PORTING.md for the feature parity matrix.
struct MainView: View {

    var app: AdwaitaApp
    var window: AdwaitaWindow

    /// A pushed page (the navigation component).
    enum Route: CustomStringConvertible, Equatable {
        case thread(uri: String)
        case profile(key: String)
        case conversation(id: String, title: String)

        var description: String {
            switch self {
            case .thread: return "Thread"
            case .profile: return "Profile"
            case .conversation(_, let title): return title
            }
        }
    }

    /// Sidebar destinations. Feeds use `feed:<uri>`; everything else is
    /// one of the fixed ids below.
    enum PaneID {
        static let home = "home"
        static let search = "search"
        static let activity = "activity"
        static let messages = "messages"
        static let profile = "profile"
        static let bookmarks = "bookmarks"
        static let liked = "liked"
        static let drafts = "drafts"
        static let ghosts = "ghosts"
        static let settings = "settings"
        static let feedPrefix = "feed:"
    }

    struct SidebarEntry: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        var avatarURL: URL? = nil
        var badge: Int = 0
    }

    // Login form
    @State var handle = ""
    @State var appPassword = ""
    @State var twoFactorCode = ""

    // Shell
    @State var sidebarSelection = PaneID.home
    @State var narrow = false
    @State var showContent = false
    @State var navStack = NavigationStack<Route>()
    /// Fired when a sidebar pick should close every pushed page.
    @State var popToRootSignal = Signal()
    @State var errorVisible = false
    @State var errorMessage = ""
    @State var toastMessage = ""
    @State var toastSignal = Signal()
    @State var aboutVisible = false

    // Composer
    @State var composeVisible = false
    @State var composeImagePicker = Signal()
    @State var composeTargetSlot = 0
    /// Where the quoted post came from, so its row turns green on success.
    @State var composeQuoteSource: RowActions? = nil
    @State var draftSavedToastPending = false

    // Search pane
    @State var searchQuery = ""
    @State var searchCategory = SearchCategory.posts.rawValue
    @State var searchSort = SearchViewModel.SearchSort.top.rawValue

    // Activity pane
    @State var activityCategory = ActivityCategory.notifications.rawValue

    // Thread pages (one entry visible at a time; cleared on send)
    @State var threadReplyText = ""
    @State var timelineScrollTop = Signal()
    /// HLS playlists the user tapped play on — those rows swap the
    /// thumbnail for an inline GStreamer player (with its own transport
    /// controls; closing it tears the pipeline down).
    @State var playingVideos: Set<String> = []

    // Messages
    @State var messageText = ""
    @State var newMessageVisible = false
    @State var newMessageQuery = ""
    @State var sendPostVisible = false
    @State var sendPostQuery = ""

    // Profile
    @State var editProfileVisible = false
    @State var editDisplayName = ""
    @State var editBio = ""
    @State var editAvatarData: Data? = nil
    @State var editAvatarPicker = Signal()
    @State var profileFilter = ProfileFeedFilter.posts.rawValue
    @State var blockConfirmKey: String? = nil

    // Library
    @State var bookmarkFolderID: String? = nil
    @State var folderDialogVisible = false
    @State var folderNameInput = ""
    @State var folderRenameID: String? = nil
    @State var folderDeleteID: String? = nil
    @State var settingsColorScheme = Desktop.ColorScheme.current.rawValue

    // Per-row popovers (only one open at a time)
    @State var repostMenuURI: String? = nil
    @State var moreMenuURI: String? = nil

    /// Bumped after every async core operation so Adwaita re-reads the
    /// model snapshots below — the models themselves aren't view state.
    /// ModelObserver and ImageLoader bump it too (see onAppear).
    @State var tick = 0

    // MARK: - Model snapshots (read through onMain, refreshed via tick)

    var isAuthenticated: Bool {
        _ = tick
        return onMain { AppSession.shared.service.isAuthenticated }
    }

    var isBusy: Bool {
        _ = tick
        return onMain { AppSession.shared.service.isLoading }
    }

    var requiresTwoFactor: Bool {
        _ = tick
        return onMain { AppSession.shared.service.requiresTwoFactor }
    }

    var currentHandle: String {
        _ = tick
        return onMain { AppSession.shared.service.currentHandle } ?? ""
    }

    var currentUserDID: String? {
        _ = tick
        return onMain { AppSession.shared.service.currentUserDID }
    }

    var ghostsEnabled: Bool {
        _ = tick
        return GhostPostPolicy.isEnabled
    }

    // MARK: - Body

    var view: Body {
        VStack {
            if isAuthenticated {
                signedInShell
            } else {
                loginPage
                    .topToolbar {
                        HeaderBar.empty()
                    }
            }
        }
        .alertDialog(visible: $errorVisible, heading: "Something went wrong", body: errorMessage, id: "error")
        .response("OK", role: .close) { }
        .dialog(
            visible: composeVisibleBinding,
            title: composeTitle,
            id: "compose",
            width: 560,
            height: 520
        ) {
            dialogPage { composeContent }
        }
        .dialog(visible: $newMessageVisible, title: "New Message", id: "new-message", width: 420, height: 560) {
            dialogPage { newMessageContent }
        }
        .dialog(visible: sendPostVisibleBinding, title: "Send Post", id: "send-post", width: 420, height: 560) {
            dialogPage { sendPostContent }
        }
        .dialog(visible: $editProfileVisible, title: "Edit Profile", id: "edit-profile", width: 460, height: 460) {
            dialogPage { editProfileContent }
        }
        .dialog(visible: $folderDialogVisible, title: folderRenameID == nil ? "New Folder" : "Rename Folder", id: "folder", width: 360, height: 200) {
            dialogPage { folderDialogContent }
        }
        .alertDialog(
            visible: folderDeleteVisibleBinding,
            heading: "Delete Folder?",
            body: "Bookmarks inside move back to the top level.",
            id: "folder-delete"
        )
        .response("Cancel", role: .close) { folderDeleteID = nil }
        .response("Delete", appearance: .destructive, role: .default) { confirmDeleteFolder() }
        .alertDialog(
            visible: blockConfirmVisibleBinding,
            heading: "Block Account?",
            body: "Blocked accounts cannot reply in your threads, mention you, or otherwise interact with you.",
            id: "block"
        )
        .response("Cancel", role: .close) { blockConfirmKey = nil }
        .response("Block", appearance: .destructive, role: .default) { confirmBlock() }
        .aboutDialog(
            visible: $aboutVisible,
            app: "@omic",
            developer: "stoicswe",
            version: appVersion,
            icon: .custom(name: "com.stoicswe.atmo")
        )
        .toast(toastMessage, signal: $toastSignal)
        .onAppear {
            MainLoopBridge.install()
            Desktop.installDevIconPath()
            Desktop.ColorScheme.current.apply()
            onMain { ImageLoader.shared.onUpdate = { tick += 1 } }
            runCore {
                await AppSession.shared.service.restoreSession()
                if AppSession.shared.service.isAuthenticated {
                    startSignedInSession()
                }
            }
        }
    }

    /// Dialog contents under an AdwHeaderBar: the dialog's title plus a
    /// close button, so every sheet can be dismissed by mouse (GNOME
    /// convention; Escape alone is swallowed by search entries).
    @ViewBuilder func dialogPage(@ViewBuilder _ content: @escaping () -> Body) -> Body {
        VStack {
            content()
        }
        .topToolbar {
            HeaderBar.empty()
        }
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? ProcessInfo.processInfo.environment["SNAP_VERSION"]
            ?? "dev"
    }

    // MARK: - Signed-in shell

    @ViewBuilder var signedInShell: Body {
        NavigationSplitView {
            sidebarPane
                .topToolbar {
                    HeaderBar.empty()
                }
                .navigationTitle("@omic")
        } content: {
            NavigationView($navStack, "@omic") { route in
                routePage(route)
                    .topToolbar {
                        // Empty AdwHeaderBar: the navigation view supplies
                        // the back button and the route's title.
                        HeaderBar.empty()
                    }
            } initialView: {
                ViewStack(id: paneID) { id in
                    pane(for: id)
                }
                .topToolbar {
                    contentHeaderBar
                }
            }
            .inspect { storage, data, _ in
                // Selecting a sidebar destination closes pushed pages —
                // the toolkit's own "popped" handler keeps its page list
                // in step. Blocked: `Signal.update` writes state back.
                data.stateManager.withBlockedUpdates {
                    guard popToRootSignal.update else { return }
                    while adw_navigation_view_pop(storage.opaquePointer) != 0 { }
                }
            }
            .navigationTitle(paneTitle)
        }
        .collapsed(narrow)
        .showContent($showContent)
        .breakpoint(maxWidth: 700, matches: $narrow)
    }

    @ViewBuilder func routePage(_ route: Route) -> Body {
        switch route {
        case .thread(let uri):
            threadPage(uri: uri)
        case .profile(let key):
            profilePage(key: key, embedded: false)
        case .conversation(let id, _):
            conversationPage(convoID: id)
        }
    }

    /// The pane the content side shows; every custom feed shares the
    /// timeline pane.
    var paneID: String {
        sidebarSelection.hasPrefix(PaneID.feedPrefix) ? PaneID.home : sidebarSelection
    }

    var paneTitle: String {
        switch paneID {
        case PaneID.home: return timelineFeedName
        case PaneID.search: return "Search"
        case PaneID.activity: return "Activity"
        case PaneID.messages: return "Messages"
        case PaneID.profile: return "Profile"
        case PaneID.bookmarks: return bookmarkPaneTitle
        case PaneID.liked: return "Liked"
        case PaneID.drafts: return "Drafts"
        case PaneID.ghosts: return "Ghosts"
        case PaneID.settings: return "Settings"
        default: return "@omic"
        }
    }

    @ViewBuilder func pane(for id: String) -> Body {
        switch id {
        case PaneID.home: timelinePane
        case PaneID.search: searchPane
        case PaneID.activity: notificationsPane
        case PaneID.messages: messagesPane
        case PaneID.profile: profilePage(key: AppSession.ownProfileKey, embedded: true)
        case PaneID.bookmarks: bookmarksPane
        case PaneID.liked: likedPane
        case PaneID.drafts: draftsPane
        case PaneID.ghosts: ghostsPane
        case PaneID.settings: settingsPane
        default: timelinePane
        }
    }

    // MARK: - Sidebar

    var pinnedFeeds: [CustomFeedItem] {
        _ = tick
        return onMain { SavedFeedsStore.shared.pinned }
    }

    var unpinnedFeeds: [CustomFeedItem] {
        _ = tick
        return onMain { SavedFeedsStore.shared.unpinned }
    }

    var unreadActivityCount: Int {
        _ = tick
        return onMain { AppSession.shared.notifications?.unreadCount ?? 0 }
    }

    var primaryEntries: [SidebarEntry] {
        var entries = [SidebarEntry(id: PaneID.home, title: "Home", icon: "user-home-symbolic")]
        for feed in pinnedFeeds {
            entries.append(SidebarEntry(
                id: PaneID.feedPrefix + feed.uri, title: feed.displayName,
                icon: "view-list-symbolic", avatarURL: feed.avatarURL
            ))
        }
        entries += [
            SidebarEntry(id: PaneID.search, title: "Search", icon: "system-search-symbolic"),
            SidebarEntry(id: PaneID.activity, title: "Activity", icon: "preferences-system-notifications-symbolic", badge: unreadActivityCount),
            SidebarEntry(id: PaneID.messages, title: "Messages", icon: "chat-message-new-symbolic"),
            SidebarEntry(id: PaneID.profile, title: "Profile", icon: "avatar-default-symbolic"),
        ]
        return entries
    }

    var libraryEntries: [SidebarEntry] {
        var entries = [
            SidebarEntry(id: PaneID.bookmarks, title: "Bookmarks", icon: "user-bookmarks-symbolic"),
            SidebarEntry(id: PaneID.liked, title: "Liked", icon: "atmo-heart-filled-symbolic"),
            SidebarEntry(id: PaneID.drafts, title: "Drafts", icon: "document-edit-symbolic"),
        ]
        if ghostsEnabled {
            entries.append(SidebarEntry(id: PaneID.ghosts, title: "Ghosts", icon: "weather-fog-symbolic"))
        }
        entries.append(SidebarEntry(id: PaneID.settings, title: "Settings", icon: "emblem-system-symbolic"))
        return entries
    }

    var feedEntries: [SidebarEntry] {
        unpinnedFeeds.map {
            SidebarEntry(id: PaneID.feedPrefix + $0.uri, title: $0.displayName, icon: "view-list-symbolic", avatarURL: $0.avatarURL)
        }
    }

    var sidebarBinding: Binding<String> {
        Binding(get: { sidebarSelection }, set: { selectSidebar($0) })
    }

    @ViewBuilder var sidebarPane: Body {
        ScrollView {
            VStack(spacing: 4) {
                sidebarList(primaryEntries)
                sidebarHeader("Library")
                sidebarList(libraryEntries)
                if !feedEntries.isEmpty {
                    sidebarHeader("Feeds")
                    sidebarList(feedEntries)
                }
                accountFooter
            }
            .padding(6)
        }
        .vexpand()
    }

    @ViewBuilder func sidebarHeader(_ title: String) -> Body {
        Text(title)
            .style("caption-heading")
            .style("dim-label")
            .halign(.start)
            .padding(6, .horizontal)
            .padding(10, .top)
    }

    /// One section of the sidebar. Every section shares the selection
    /// binding; a section that doesn't own the selected id clears its own
    /// highlight (GtkListBox keeps a stale selection otherwise).
    @ViewBuilder func sidebarList(_ entries: [SidebarEntry]) -> Body {
        let ownsSelection = entries.contains { $0.id == sidebarSelection }
        List(entries, selection: sidebarBinding) { entry in
            sidebarRow(entry)
        }
        .sidebarStyle()
        .inspect { storage, _, updateProperties in
            guard updateProperties, !ownsSelection else { return }
            gtk_list_box_unselect_all(storage.opaquePointer)
        }
    }

    @ViewBuilder func sidebarRow(_ entry: SidebarEntry) -> Body {
        HStack(spacing: 10) {
            if entry.avatarURL != nil {
                remoteAvatar(url: entry.avatarURL, name: entry.title, size: 20)
            } else {
                Symbol(icon: .custom(name: entry.icon))
            }
            Text(entry.title)
                .ellipsize()
                .halign(.start)
                .hexpand()
            if entry.badge > 0 {
                Text("\(entry.badge)")
                    .style("caption")
                    .style("badge")
                    .style("accent")
            }
        }
        .padding(6, .horizontal)
        .padding(4, .vertical)
    }

    /// Signed-in account at the bottom of the sidebar, like the macOS
    /// sidebar's account row: opens the profile pane.
    @ViewBuilder var accountFooter: Body {
        let profile = ownProfileSnapshot
        HStack(spacing: 10) {
            remoteAvatar(url: profile?.avatarURL, name: profile?.name ?? currentHandle, size: 28)
            VStack(spacing: 0) {
                Text(profile?.name ?? currentHandle)
                    .ellipsize()
                    .style("heading")
                    .halign(.start)
                Text("@\(currentHandle)")
                    .ellipsize()
                    .style("dim-label")
                    .style("caption")
                    .halign(.start)
            }
            .hexpand()
        }
        .padding(8)
        .padding(12, .top)
        .onClick { selectSidebar(PaneID.profile) }
    }

    func selectSidebar(_ id: String) {
        guard id != sidebarSelection || narrow else { return }
        sidebarSelection = id
        popToRootSignal.signal()
        if narrow { showContent = true }
        if id.hasPrefix(PaneID.feedPrefix) {
            let uri = String(id.dropFirst(PaneID.feedPrefix.count))
            let name = (pinnedFeeds + unpinnedFeeds).first { $0.uri == uri }?.displayName ?? "Feed"
            runCore { await AppSession.shared.timeline?.setFeedSource(.custom(uri: uri, displayName: name)) }
        } else {
            switch id {
            case PaneID.home:
                runCore {
                    guard let timeline = AppSession.shared.timeline, !timeline.feedSource.isFollowing else { return }
                    await timeline.setFeedSource(.following)
                }
            case PaneID.messages:
                runCore { await AppSession.shared.dms?.load() }
            case PaneID.profile:
                loadProfile(key: AppSession.ownProfileKey)
            case PaneID.liked:
                runCore { await LikedPostsStore.shared.continueBackfill(service: AppSession.shared.service) }
            case PaneID.activity:
                runCore { await AppSession.shared.notifications?.load() }
            default:
                break
            }
        }
    }

    // MARK: - Header bar

    @ViewBuilder var contentHeaderBar: Body {
        HeaderBar {
            Button(icon: .custom(name: "sidebar-show-symbolic")) { showContent = false }
                .tooltip("Sidebar")
                .flat()
                .visible(narrow)
        } end: {
            // GTK packs `end` children from the right: the primary menu
            // is listed first so it lands at the far edge, per the HIG.
            Menu(icon: .custom(name: "open-menu-symbolic")) {
                MenuButton("Search") { selectSidebar(PaneID.search) }
                    .keyboardShortcut("f".ctrl())
                MenuButton("Settings") { selectSidebar(PaneID.settings) }
                    .keyboardShortcut("comma".ctrl())
                MenuButton("About @omic") { aboutVisible = true }
                MenuButton("Sign Out (@\(currentHandle))") { signOut() }
            }
            .primary()
            .tooltip("Main Menu")
            Button(icon: .custom(name: "document-edit-symbolic")) { openComposer() }
                .keyboardShortcut("n".ctrl())
                .tooltip("New Post")
                .flat()
            Button(icon: .custom(name: "view-refresh-symbolic")) { refreshCurrentPane() }
                .keyboardShortcut("r".ctrl())
                .tooltip("Refresh")
                .flat()
            paneHeaderActions
        }
        .headerBarTitle {
            WindowTitle(subtitle: paneSubtitle, title: paneTitle)
        }
    }

    var paneSubtitle: String {
        switch paneID {
        case PaneID.home where !timelineIsFollowing: return "Custom feed"
        case PaneID.activity where unreadActivityCount > 0: return "\(unreadActivityCount) unread"
        default: return ""
        }
    }

    /// Pane-specific header buttons (New Folder, New Message, Edit
    /// Profile, feed pin/unsubscribe), mirroring the macOS toolbars.
    @ViewBuilder var paneHeaderActions: Body {
        switch paneID {
        case PaneID.home:
            timelineHeaderActions
        case PaneID.messages:
            Button(icon: .custom(name: "list-add-symbolic")) { openNewMessage() }
                .tooltip("New Message")
                .flat()
        case PaneID.bookmarks:
            HStack(spacing: 0) {
                bookmarksHeaderActions
            }
        default:
            [] as Body
        }
    }

    // MARK: - Async plumbing

    /// Runs a MainActor operation against AtmoCore and re-renders when it
    /// finishes. Requires MainLoopBridge (installed in onAppear); every
    /// continuation resumes on the GTK main thread.
    func runCore(_ operation: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            await operation()
            tick += 1
        }
    }

    /// Post-authentication setup shared by session restore and sign-in:
    /// builds the view models, starts observing them, loads initial data.
    func startSignedInSession() {
        onMain { AppSession.shared.buildViewModels() }
        startModelObservation()
        runCore {
            let session = AppSession.shared
            await session.timeline?.loadInitial()
            await session.notifications?.load()
            await SavedFeedsStore.shared.load(service: session.service)
            await session.profileSession(for: AppSession.ownProfileKey).profile.load()
        }
    }

    /// Re-renders whenever the shared view models change on their own
    /// schedule — the 60 s silent timeline refresh, search's debounced
    /// fetches — not just after this view's own awaits. Stops itself at
    /// sign-out (models gone); started again by the next sign-in.
    func startModelObservation() {
        onMain {
            startModelObservationOnMain()
        }
    }

    @MainActor
    private func startModelObservationOnMain() {
        ModelObserver.observe {
            guard let timeline = AppSession.shared.timeline,
                  let notifications = AppSession.shared.notifications,
                  let search = AppSession.shared.search,
                  let dms = AppSession.shared.dms else { return false }
            _ = timeline.posts
            _ = timeline.isLoading
            _ = timeline.newPostsCount
            _ = timeline.feedSource
            _ = notifications.notifications
            _ = notifications.unreadCount
            _ = search.postResults
            _ = search.peopleResults
            _ = search.hashtagResults
            _ = search.feedResults
            _ = search.isLoading
            _ = dms.conversations
            _ = SavedFeedsStore.shared.pinned
            _ = SavedFeedsStore.shared.unpinned
            _ = BookmarkStore.shared.bookmarks
            _ = BookmarkFolderStore.shared.state
            _ = LikedPostsStore.shared.likedPosts
            _ = LikedPostsStore.shared.isBackfilling
            _ = DraftStore.shared.drafts
            _ = GhostPostStore.shared.active
            _ = GhostPostStore.shared.archive
            _ = SearchHistoryStore.shared.entries
            _ = SearchHistoryStore.shared.isEnabled
            return true
        } onChange: {
            tick += 1
        }
    }

    func refreshCurrentPane() {
        runCore {
            let session = AppSession.shared
            switch paneID {
            case PaneID.home: await session.timeline?.refresh()
            case PaneID.activity: await session.notifications?.load()
            case PaneID.search: session.search?.refresh()
            case PaneID.messages: await session.dms?.load()
            case PaneID.profile: await session.profileSession(for: AppSession.ownProfileKey).profile.load()
            case PaneID.liked: await LikedPostsStore.shared.continueBackfill(service: session.service)
            default: break
            }
        }
    }

    // MARK: - Navigation

    /// Pushes a thread page for the given post and starts loading it.
    func openThread(uri: String) {
        navStack.push(.thread(uri: uri))
        runCore {
            let session = AppSession.shared.threadSession(for: uri)
            await session.thread.load()
            session.interactions.seedPosts(session.thread.allPosts)
        }
    }

    /// Pushes a profile page (DID or handle); the signed-in user's own
    /// profile lands on the Profile pane instead of a pushed copy.
    func openProfile(actor: String) {
        let key = onMain { AppSession.shared.profileKey(for: actor) }
        if key == AppSession.ownProfileKey {
            selectSidebar(PaneID.profile)
            return
        }
        navStack.push(.profile(key: key))
        loadProfile(key: key)
    }

    func loadProfile(key: String) {
        runCore {
            let session = AppSession.shared.profileSession(for: key)
            if session.profile.profile == nil || key == AppSession.ownProfileKey {
                await session.profile.load()
            }
            AppSession.shared.syncProfileInteractions(for: key)
        }
    }

    func openConversation(_ conversation: ConversationItem) {
        let title = conversationTitle(conversation)
        navStack.push(.conversation(id: conversation.convoID, title: title))
        runCore { await AppSession.shared.conversation(for: conversation.convoID).load() }
    }

    /// Switches to the Search pane with a hashtag query.
    func openHashtagSearch(_ tag: String) {
        selectSidebar(PaneID.search)
        searchQuery = "#\(tag)"
        searchCategory = SearchCategory.posts.rawValue
        syncSearchQuery()
    }

    /// Switches to the Search pane with an author query.
    func openAuthorSearch(handle: String) {
        selectSidebar(PaneID.search)
        searchQuery = "from:\(handle)"
        searchCategory = SearchCategory.posts.rawValue
        syncSearchQuery()
    }

    /// Link activations inside post text: mentions and hashtags stay in
    /// the app, everything else opens in the browser.
    func handleLink(_ uri: String) -> Bool {
        guard let target = RichTextMarkup.target(for: uri) else { return false }
        switch target {
        case .profile(let actor):
            openProfile(actor: actor)
            return true
        case .hashtag(let tag):
            openHashtagSearch(tag)
            return true
        case .web:
            return false
        }
    }

    func signOut() {
        popToRootSignal.signal()
        sidebarSelection = PaneID.home
        runCore {
            await AppSession.shared.service.logout()
            AppSession.shared.reset()
            MainLoopBridge.flushDefaults()
        }
    }

    func presentError(_ message: String) {
        errorMessage = message
        errorVisible = true
    }

    func showToast(_ message: String) {
        toastMessage = message
        toastSignal.signal()
    }
}
