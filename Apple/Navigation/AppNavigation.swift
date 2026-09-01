import SwiftUI
import AtmoCore

// MARK: - Sidebar Items
enum SidebarItem: String, CaseIterable, Identifiable {
    case timeline      = "Home"
    case search        = "Search"
    case notifications = "Activity"
    case messages      = "Messages"
    case profile       = "Profile"
    case bookmarks     = "Bookmarks"
    case drafts        = "Drafts"
    case settings      = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .timeline:      return "house"
        case .search:        return "magnifyingglass"
        case .notifications: return "bell"
        case .messages:      return "bubble.left.and.bubble.right"
        case .profile:       return "person.circle"
        case .bookmarks:     return "bookmark"
        case .drafts:        return "doc.text"
        case .settings:      return "gearshape"
        }
    }

    var filledIcon: String {
        switch self {
        case .timeline:      return "house.fill"
        case .search:        return "magnifyingglass"
        case .notifications: return "bell.fill"
        case .messages:      return "bubble.left.and.bubble.right.fill"
        case .profile:       return "person.circle.fill"
        case .bookmarks:     return "bookmark.fill"
        case .drafts:        return "doc.text.fill"
        case .settings:      return "gearshape.fill"
        }
    }
}

// Items shown in the scrollable top section of the sidebar
private let primaryItems: [SidebarItem] = [.timeline, .search, .notifications, .messages]
// Items pinned to the bottom of the sidebar panel (profile → bookmarks → drafts → settings)
private let bottomItems:  [SidebarItem] = [.profile, .bookmarks, .drafts, .settings]

#if os(iOS)
// MARK: - Phone Bar Configuration
/// User-configurable bottom-menu composition for the iPhone shell
/// (Settings → Appearance → Customize Bottom Menu). Home is always pinned
/// first; up to three chosen items join it, and everything else lives in
/// the left drawer.
enum PhoneBarConfig {
    static let storageKey = "atmo.phone.barItems"
    static let defaultValue = "Search,Activity,Profile"
    /// Whether the bar's buttons show text labels under their icons.
    static let labelsKey = "atmo.phone.barLabels"
    static let maxCustomTabs = 3
    /// Everything that can be placed in either the bar or the drawer.
    static let eligible: [SidebarItem] =
        [.search, .notifications, .messages, .profile, .bookmarks, .drafts, .settings]

    static func decode(_ raw: String) -> [SidebarItem] {
        raw.split(separator: ",")
            .compactMap { SidebarItem(rawValue: String($0)) }
            .filter { eligible.contains($0) }
    }

    static func encode(_ items: [SidebarItem]) -> String {
        items.map(\.rawValue).joined(separator: ",")
    }
}

/// Shared chrome state for the iPhone shell. Scrollable views (the feed)
/// collapse the bottom bar on scroll-down and restore it on scroll-up,
/// mirroring the native tab bar's minimize behavior.
@MainActor
@Observable
final class PhoneChromeState {
    static let shared = PhoneChromeState()
    /// True while the tab pill is minimized to a single corner button.
    var barCollapsed = false
    /// Whether the home timeline is resting at its top — drives the Home
    /// tab's arrow morphing.
    var timelineAtTop = true
    /// Incremented to ask the timeline to jump to its top (Home button
    /// while scrolled, drawer Home, new-posts pill).
    var scrollToTopRequest = 0
    /// Incremented to ask the timeline to jump BACK to where the user was
    /// before the last scroll-to-top (Home button's down-arrow state).
    var scrollBackRequest = 0
    /// True while a pre-jump position is stored to return to.
    var timelineReturnAvailable = false
    /// True while a DM conversation is on top of the stack. The app bar
    /// steps aside entirely — the conversation renders its own composer
    /// via a view-local safeAreaInset, which is the only reliable way to
    /// keep its message list inset above the input on pushed screens.
    var conversationOpen = false

    /// Non-nil while a thread screen is on top: the bar shows [Home] +
    /// [compose-as-reply], and the compose circle calls this.
    private(set) var threadReply: (@MainActor () -> Void)? = nil
    private var threadReplyOwner: UUID? = nil

    /// Owner-token registration: on a push, the NEW thread registers before
    /// the covered one's onDisappear fires — the token keeps that stale
    /// unregister from clobbering the fresh registration.
    func registerThread(owner: UUID, reply: @escaping @MainActor () -> Void) {
        threadReplyOwner = owner
        threadReply = reply
    }

    func unregisterThread(owner: UUID) {
        guard threadReplyOwner == owner else { return }
        threadReplyOwner = nil
        threadReply = nil
    }
}
#endif

// MARK: - Root Navigation
struct AppNavigation: View {
    @Environment(ATProtoService.self) private var service
    @State private var selectedItem: SidebarItem? = .timeline
    @State private var showComposer: Bool = false
    /// When non-nil, opens the composer sheet pre-loaded with this draft.
    @State private var draftToResume: ComposerDraft? = nil
    /// Drives the "Draft saved" toast that appears after an implicit swipe-dismiss.
    @State private var showDraftSavedToast: Bool = false
    /// Recipient picker for a new DM (the "+" on the Messages page).
    /// Declared and presented at the SAME level as the composer sheet —
    /// the one presentation point verified to work everywhere.
    @State private var showNewConversation: Bool = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
#if os(iOS)
    /// iPhone: whether the left drawer menu is open.
    @State private var phoneMenuOpen = false
    /// Live translation of an in-flight edge swipe opening the drawer
    /// (nil when no drag is active). Drives the drawer offset directly so
    /// the menu tracks the finger.
    @State private var phoneMenuDragX: CGFloat? = nil
    /// Drawer travel at the last ratchet tick — the gritty haptic fires
    /// every `menuTickSpacing` points of slide.
    @State private var phoneMenuLastTickX: CGFloat = 0
    /// iPhone: user-chosen bottom-bar items (comma-joined rawValues).
    @AppStorage(PhoneBarConfig.storageKey) private var phoneBarItemsRaw = PhoneBarConfig.defaultValue
    /// iPhone: text labels under the bar icons (Settings → Appearance).
    @AppStorage(PhoneBarConfig.labelsKey) private var phoneBarShowsLabels = false
    /// iPhone: focus for the bottom-bar search field — hoisted here so the
    /// dismiss-keyboard circle can clear it through SwiftUI (a raw
    /// resignFirstResponder fought the FocusState and needed two taps).
    @FocusState private var phoneSearchFocused: Bool
    /// iPhone: shared bar-minimize state, written by scrolling views.
    private let phoneChrome = PhoneChromeState.shared

    /// Home plus the user's chosen tabs, in their chosen order.
    private var phoneTabItems: [SidebarItem] {
        [.timeline] + Array(PhoneBarConfig.decode(phoneBarItemsRaw).prefix(PhoneBarConfig.maxCustomTabs))
    }

    /// Everything eligible that isn't in the bar goes to the drawer.
    private var phoneDrawerItems: [SidebarItem] {
        let tabs = phoneTabItems
        return PhoneBarConfig.eligible.filter { !tabs.contains($0) }
    }
#endif

    /// Bound to AtmoApp — set when the user taps a Spotlight bookmark result.
    /// When non-nil, we navigate immediately to that post's ThreadView then clear it.
    @Binding var spotlightPostURI: String?

    // Persistent ViewModels — owned here so they survive sidebar/tab switches.
    // Each is lazily initialised on first use (needs service).
    @State private var timelineViewModel: TimelineViewModel?
    @State private var searchViewModel: SearchViewModel?
    /// Background DM poll (cache + incoming-message notifications); lives
    /// for the whole session, independent of the Messages page.
    @State private var messagesMonitor: MessagesMonitor?

    // Single NavigationPath for the split-view detail column.
    // Owned here (not inside TimelineView) so it survives sidebar switches.
    @State private var splitNavPath = NavigationPath()

    // Owned NavigationPath for the iPhone timeline tab — lets us push a
    // Spotlight-opened thread onto the timeline stack from AppNavigation.
    @State private var phoneTimelineNavPath = NavigationPath()

    // Sidebar rows don't inherit the tint environment on macOS — their
    // icons take the asset-catalog accent instead. Observing the preset
    // here and applying it via listItemTint keeps the sidebar in sync
    // with Settings → Appearance, live.
    @AppStorage(ThemeKeys.accentPresetID) private var accentPresetID: String = AccentPresets.defaultID
    private var sidebarTint: Color {
        AccentPresets.preset(forID: accentPresetID).color
    }

    var body: some View {
        // Under-13 gate: the declared age range disables social media
        // capabilities for children entirely (App Store age-rating
        // posture) — the gate replaces the whole app, and the family
        // integration stays attached so a re-probe can lift it.
        if ParentalControlsStore.shared.isChildAccount {
            ChildAccountGateView()
                .integratesFamilyControls()
        } else {
            appContent
        }
    }

    private var appContent: some View {
        platformView
            // Inject the hashtag search action into the environment so any descendant
            // (FeedItemView, ThreadView, etc.) can open Search pre-filled with a tag
            // without requiring explicit callback threading through intermediate views.
            .environment(\.openFeed, OpenFeedAction { [self] feed in
                switchTimelineFeed(feed)
                selectedItem = .timeline
            })
            .environment(\.hashtagSearch, HashtagSearchAction { [self] tag in
                let vm = getOrCreateSearchViewModel()
                vm.activateHashtag(tag)
                selectedItem = .search
            })
            // Inject the draft-saved notification so ComposerView can trigger the
            // "Draft saved" toast from anywhere in the hierarchy (timeline reply,
            // quote post, FAB) without requiring explicit callback threading.
            .environment(\.draftSaved, DraftSavedAction {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    showDraftSavedToast = true
                }
            })
            .sheet(isPresented: $showComposer, onDismiss: handleComposerDismiss) {
                ComposerView()
            }
            // New-DM recipient picker; opening a person pushes their
            // conversation onto the phone stack.
            .sheet(isPresented: $showNewConversation) {
                NewConversationView { convo in
                    selectedItem = .messages
                    phoneTimelineNavPath.append(convo)
                }
            }
            // Opened when the user taps a draft row in DraftsView.
            // ComposerViewModel.restoreDraft() picks up the saved text from
            // DraftStore automatically via the matching replyToURI / quotedPostURI.
            // Image data is not re-attached (only filenames are stored in drafts).
            .sheet(item: $draftToResume, onDismiss: handleComposerDismiss) { _ in
                ComposerView()
            }
            .overlay(alignment: .bottom) {
                if showDraftSavedToast {
                    DraftSavedToast()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 100)
                        .zIndex(100)
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                showDraftSavedToast = false
                            }
                        }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: showDraftSavedToast)
#if os(iOS)
            // Background-publish status: progress while PostPublisher works
            // through a queued post, then the posted/failed receipt. The
            // Live Activity mirrors the same state outside the app.
            .overlay(alignment: .top) {
                PostPublishStatusPill()
                    .padding(.top, AtmoTheme.Spacing.sm)
                    .zIndex(99)
            }
#endif
            // Navigate to a bookmarked post opened via Spotlight search.
            // Switches to the Timeline tab (so Back works) then pushes the thread
            // onto whichever navigation stack is active for the current platform.
            .onChange(of: spotlightPostURI) { _, uri in
                guard let uri else { return }
                selectedItem = .timeline
                let target = NavigationPath([PostNavTarget(uri: uri)])
                // Split view (iPad / macOS) uses splitNavPath.
                // Phone TabView uses the owned phoneTimelineNavPath.
#if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    phoneTimelineNavPath = target
                } else {
                    splitNavPath = target
                }
#else
                splitNavPath = target
#endif
                spotlightPostURI = nil   // consume — prevents re-triggering on redraw
            }
            // Applied outermost so every subtree — sheets included — resolves
            // web links to the in-app browser on iOS. (Sheets containing
            // links still host their own copy; see InAppBrowserHost.)
            .hostsInAppBrowser()
            // Declared Age Range probe + PermissionKit response listener.
            .integratesFamilyControls()
            .task {
                // Create persistent VMs eagerly on first appearance.
                // Crucially, kick off the initial timeline fetch here — in the
                // AppNavigation task — rather than relying solely on TimelineView's
                // own .task, which may be delayed or not yet reached on macOS split view
                // (the detail column renders lazily and its .task can race with session restore).
                if timelineViewModel == nil {
                    let vm = TimelineViewModel(service: service)
                    timelineViewModel = vm
                    // Start the fetch immediately. If atProtoKit is already available
                    // (session restored before navigation appeared), this loads right away.
                    // If not yet available, TimelineView's .onChange(of: service.atProtoKit)
                    // will catch it once the session finishes restoring.
                    await vm.loadInitial()
                }
                if searchViewModel == nil {
                    searchViewModel = SearchViewModel(service: service)
                }
                if messagesMonitor == nil {
                    // Background DM poll: keeps the Messages cache warm and
                    // raises a notification when an incoming message lands.
                    messagesMonitor = MessagesMonitor(service: service)
                }
            }
            // Saved custom feeds for the drawer/sidebar shelves — keyed on
            // the session DID so it re-runs once restore completes (a
            // launch-time run fires before the session exists).
            .task(id: service.currentUserDID) {
                await SavedFeedsStore.shared.load(service: service)
            }
    }

    // MARK: - Platform Branching
    @ViewBuilder
    private var platformView: some View {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            phoneTabView
        } else {
            splitView
        }
#else
        splitView
#endif
    }

    // MARK: - iPad / macOS Split View
    // Custom sidebar: scrollable primary items at top, Profile + Settings pinned at bottom.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // One native sidebar List, sectioned like Mail/Notes: every row
            // gets the system selection highlight, hover states, spacing,
            // and badge rendering — no custom-styled rows.
            List(selection: $selectedItem) {
                // Mirrors the iPhone drawer: Home with the pinned feeds
                // directly beneath it (the quick-switch shelf), then the
                // rest of the primary items.
                Section {
                    sidebarFeedRow(nil)
                    ForEach(SavedFeedsStore.shared.pinned) { feed in
                        sidebarFeedRow(feed)
                    }
                    ForEach(primaryItems.filter { $0 != .timeline }) { item in
                        sidebarLabel(for: item)
                            .tag(item)
                            .listItemTint(.fixed(sidebarTint))
                    }
                }

                Section("Library") {
                    ForEach(bottomItems) { item in
                        sidebarLabel(for: item)
                            .tag(item)
                            .listItemTint(.fixed(sidebarTint))
                    }
                }

                // Saved-but-unpinned feeds, like the drawer's Feeds block.
                if !SavedFeedsStore.shared.unpinned.isEmpty {
                    Section("Feeds") {
                        ForEach(SavedFeedsStore.shared.unpinned) { feed in
                            sidebarFeedRow(feed)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Wide enough that "Notifications" and "Messages" don't truncate.
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .navigationTitle("@omic")
        } detail: {
            // One NavigationStack owns the entire detail column.
            // All navigationDestination registrations live here so there is
            // never more than one stack active at a time — avoiding the SwiftUI
            // "multiple stacks / conflicting destinations" runtime warning that
            // caused the blank-with-warning-triangle symptom.
            NavigationStack(path: $splitNavPath) {
                ZStack(alignment: .bottomTrailing) {
                    persistentDetailStack

                    // Liquid Glass FAB — always on top
                    ComposeFAB { showComposer = true }
                        .padding(.trailing, AtmoTheme.Spacing.xxl)
                        .padding(.bottom, AtmoTheme.Spacing.xxl)
                }
                // All destinations for every tab registered once here.
                // Each carries the tinted backdrop itself — pushed hosting
                // views paint their own background, so the shell-level wash
                // alone wouldn't reach them.
                .navigationDestination(for: PostNavTarget.self) { target in
                    ThreadView(postURI: target.uri)
                        .themedBackdrop()
                }
                .navigationDestination(for: String.self) { did in
                    ProfileView(actorDID: did, splitNavPath: $splitNavPath)
                        .themedBackdrop()
                }
                .navigationDestination(for: ConversationItem.self) { convo in
                    ConversationDetailView(conversation: convo)
                        .themedBackdrop()
                }
            }
            // Accent-derived wash behind every tab (Settings → Appearance).
            .themedBackdrop()
        }
    }

    /// Renders every tab destination simultaneously, showing only the selected one.
    /// Views are kept alive in the hierarchy (opacity toggle, not conditional) so
    /// their scroll position and local @State survive sidebar switches.
    /// None of these views contain their own NavigationStack — the single stack
    /// above owns all navigation for the split-view detail column.
    @ViewBuilder
    private var persistentDetailStack: some View {
        let active = selectedItem ?? .timeline

        let timelineVm = getOrCreateTimelineViewModel()
        let searchVm   = getOrCreateSearchViewModel()

        // Each view sets .navigationTitle only when it is the active tab.
        // Applying it per-view (rather than on the ZStack) prevents always-alive
        // inactive views — especially ProfileView, which sets a dynamic title
        // internally — from bleeding their title preference through the ZStack
        // onto the nav bar of a different active tab.
        ZStack {
            TimelineView(viewModel: timelineVm, splitNavPath: $splitNavPath)
                .opacity(active == .timeline ? 1 : 0)
                .allowsHitTesting(active == .timeline)
                .navigationTitle(active == .timeline ? timelineVm.feedSource.displayName : "")

            SearchView(viewModel: searchVm, splitNavPath: $splitNavPath)
                .opacity(active == .search ? 1 : 0)
                .allowsHitTesting(active == .search)
                .navigationTitle(active == .search ? "Search" : "")

            NotificationsView(embeddedInSplitView: true)
                .opacity(active == .notifications ? 1 : 0)
                .allowsHitTesting(active == .notifications)
                .navigationTitle(active == .notifications ? "Activity" : "")

            ConversationListView(embeddedInSplitView: true)
                .opacity(active == .messages ? 1 : 0)
                .allowsHitTesting(active == .messages)
                .navigationTitle(active == .messages ? "Messages" : "")

            // ProfileView no longer sets .navigationTitle when embedded in the split
            // view (splitNavPath != nil), so AppNavigation sets it here for both
            // the active and inactive states. Empty string when inactive prevents any
            // residual preference from leaking onto the active tab's nav bar.
            ProfileView(actorDID: nil, splitNavPath: $splitNavPath)
                .opacity(active == .profile ? 1 : 0)
                .allowsHitTesting(active == .profile)
                .navigationTitle(active == .profile ? "Profile" : "")

            BookmarksView(splitNavPath: $splitNavPath)
                .opacity(active == .bookmarks ? 1 : 0)
                .allowsHitTesting(active == .bookmarks)
                .navigationTitle(active == .bookmarks ? "Bookmarks" : "")

            DraftsView(splitNavPath: $splitNavPath, onOpenDraft: { draft in
                draftToResume = draft
            })
                .opacity(active == .drafts ? 1 : 0)
                .allowsHitTesting(active == .drafts)
                .navigationTitle(active == .drafts ? "Drafts" : "")

            SettingsView()
                .opacity(active == .settings ? 1 : 0)
                .allowsHitTesting(active == .settings)
                .navigationTitle(active == .settings ? "Settings" : "")
        }
    }

    private func navigationTitle(for item: SidebarItem) -> String {
        switch item {
        case .timeline:      return "Home"
        case .search:        return "Search"
        case .notifications: return "Activity"
        case .messages:      return "Messages"
        case .profile:       return "Profile"
        case .bookmarks:     return "Bookmarks"
        case .drafts:        return "Drafts"
        case .settings:      return "Settings"
        }
    }

    @ViewBuilder
    private func sidebarLabel(for item: SidebarItem) -> some View {
        let draftCount = DraftStore.shared.drafts.count
        Label(item.rawValue, systemImage: selectedItem == item ? item.filledIcon : item.icon)
            .badge(item == .drafts && draftCount > 0 ? draftCount : 0)
    }

    // MARK: - iPhone Shell
#if os(iOS)
    // Custom scaffold in place of the stock TabView:
    //  • ONE NavigationStack (same single-stack rule as the split view)
    //  • persistent content ZStack so tab state survives switches
    //  • bottom bar: [Home / Search / Activity pill] + [compose circle],
    //    Phone-app style; on the Search tab the pill morphs into a
    //    Notes-style search field
    //  • left drawer with Messages / Profile / Bookmarks / Drafts / Settings;
    //    the content scales back and dims while it's open
    /// Drawer geometry: width, travel per gritty tick, and how far a swipe
    /// must go (absent a flick) before releasing commits the open.
    private static let menuWidth: CGFloat = 290
    private static let menuTickSpacing: CGFloat = 24
    private static let menuOpenThreshold: CGFloat = 110

    /// 0 → fully hidden, 1 → fully open; tracks the finger mid-swipe.
    private var phoneMenuProgress: CGFloat {
        if phoneMenuOpen { return 1 }
        guard let x = phoneMenuDragX else { return 0 }
        return min(1, max(0, x / Self.menuWidth))
    }

    private var phoneTabView: some View {
        ZStack(alignment: .leading) {
            // The app stays put; the drawer slides OVER it with a dimming
            // scrim (no scale/push-back — transforms on the live navigation
            // hierarchy were a recurring source of glitches).
            phoneMainShell

            // Dimming scrim — always mounted so its opacity can track an
            // in-flight edge swipe; taps close only when actually open (a
            // fading or dragging scrim must never intercept the bar).
            Color.black.opacity(0.25 * phoneMenuProgress)
                .ignoresSafeArea()
                .onTapGesture { phoneMenuOpen = false }
                .allowsHitTesting(phoneMenuOpen)

            // Drawer — always mounted, positioned by offset. An offset (not
            // insertion/removal transitions) is what lets the edge swipe
            // drag it interactively without a transition fighting the finger.
            PhoneSideMenu(
                active: selectedItem,
                items: phoneDrawerItems,
                activeFeedURI: currentCustomFeedURI,
                onSelect: { item in
                    // "Home" from the drawer means the top of the FOLLOWING
                    // feed — it also leaves any custom feed, and retires the
                    // scroll-to-top circle so the bar arrives uncrowded.
                    if item == .timeline {
                        switchTimelineFeed(nil)
                        if !phoneChrome.timelineAtTop {
                            phoneChrome.scrollToTopRequest += 1
                        }
                    }
                    selectedItem = item
                    phoneMenuOpen = false
                },
                onSelectFeed: { feed in
                    switchTimelineFeed(feed)
                    selectedItem = .timeline
                    phoneMenuOpen = false
                }
            )
            .frame(width: Self.menuWidth)
            .offset(x: (phoneMenuProgress - 1) * Self.menuWidth)
            .zIndex(2)
            .allowsHitTesting(phoneMenuOpen)
            // Swipe the drawer back toward the edge to close it.
            .gesture(
                DragGesture().onEnded { value in
                    if value.translation.width < -40 { phoneMenuOpen = false }
                }
            )
        }
        // Edge swipe: slide the drawer in from the left screen edge, with a
        // gritty ratchet underneath the finger. Simultaneous so feeds keep
        // scrolling normally — the drag only captures when it starts at the
        // edge, heads right, and no screen is pushed (the system back swipe
        // owns that edge otherwise).
        .simultaneousGesture(menuEdgeSwipe)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: phoneMenuOpen)
        // Subtle pulse landing mid-slide as the drawer comes in.
        .onChange(of: phoneMenuOpen) { _, open in
            guard open else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                Haptics.soft()
            }
        }
    }

    private var menuEdgeSwipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !phoneMenuOpen else { return }
                if phoneMenuDragX == nil {
                    // Capture once, and only for a genuine edge-open: starts
                    // within the edge band, travels rightward and mostly
                    // horizontally, and the nav stack is at its root.
                    guard phoneTimelineNavPath.isEmpty,
                          value.startLocation.x <= 32,
                          value.translation.width > 0,
                          abs(value.translation.width) > abs(value.translation.height)
                    else { return }
                    phoneMenuLastTickX = 0
                }
                let x = min(max(0, value.translation.width), Self.menuWidth)
                // Gritty ratchet: a tick per band of travel, growing firmer
                // as the drawer comes further in (either direction).
                if abs(x - phoneMenuLastTickX) >= Self.menuTickSpacing {
                    phoneMenuLastTickX = x
                    Haptics.pullTick(progress: x / Self.menuWidth)
                }
                phoneMenuDragX = x
            }
            .onEnded { value in
                guard phoneMenuDragX != nil else { return }
                let x = min(max(0, value.translation.width), Self.menuWidth)
                let flungOpen = value.predictedEndTranslation.width > Self.menuWidth * 0.6
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    phoneMenuOpen = x > Self.menuOpenThreshold || flungOpen
                    phoneMenuDragX = nil
                }
            }
    }

    private var phoneMainShell: some View {
        NavigationStack(path: $phoneTimelineNavPath) {
            phonePersistentContent
                .toolbarTitleDisplayMode(.inline)
                // No nav-bar glass: content passes to the very top edge.
                // Only the status bar keeps a blur (overlay below).
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Haptics.tap()
                            phoneMenuOpen = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
                        }
                        .accessibilityLabel("Menu")
                    }
                }
                // All destinations registered once on the single stack.
                // Each carries the tinted backdrop itself (pushed hosting
                // views paint their own background).
                .navigationDestination(for: PostNavTarget.self) { target in
                    ThreadView(postURI: target.uri)
                        .themedBackdrop()
                }
                .navigationDestination(for: String.self) { did in
                    // Flat mode (shared path) — a pushed profile must NOT
                    // own a nested NavigationStack.
                    ProfileView(actorDID: did, splitNavPath: $phoneTimelineNavPath)
                        .themedBackdrop()
                }
                .navigationDestination(for: ConversationItem.self) { convo in
                    ConversationDetailView(conversation: convo)
                        .themedBackdrop()
                }
        }
        // Accent-derived wash behind every tab (Settings → Appearance).
        .themedBackdrop()
        // Floating bottom bar. safeAreaInset (not overlay) so scroll content
        // gets the inset automatically and the bar rides above the keyboard.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            phoneBottomBar
                // Sit lower, hugging the home-indicator region like the
                // native tab bar — except while the search keyboard is up,
                // where sinking would clip the field into the keyboard.
                .offset(y: phoneSearchFocused ? 0 : 22)
        }
        // Status-bar blur: with the toolbar glass hidden, this is the only
        // chrome above the content. The material runs a little past the
        // status bar and fades out through a gradient mask — a hard-edged
        // strip read as a gray band with a seam under it.
        .overlay(alignment: .top) {
            GeometryReader { geo in
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: geo.safeAreaInsets.top + 14)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.6),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .offset(y: -geo.safeAreaInsets.top)
            }
            .allowsHitTesting(false)
        }
    }

    /// The three pill tabs stay alive (opacity toggle) so their scroll
    /// position and state survive switches; drawer destinations render on
    /// demand. Titles follow the split view's pattern — set per view, only
    /// while active — so inactive views can't bleed theirs onto the bar.
    @ViewBuilder
    private var phonePersistentContent: some View {
        let active = selectedItem ?? .timeline
        let timelineVm = getOrCreateTimelineViewModel()
        let searchVm = getOrCreateSearchViewModel()

        ZStack {
            TimelineView(viewModel: timelineVm, splitNavPath: $phoneTimelineNavPath)
                .opacity(active == .timeline ? 1 : 0)
                .allowsHitTesting(active == .timeline)
                .navigationTitle(active == .timeline ? timelineVm.feedSource.displayName : "")

            SearchView(
                viewModel: searchVm,
                splitNavPath: $phoneTimelineNavPath,
                hidesSearchField: true
            )
            .opacity(active == .search ? 1 : 0)
            .allowsHitTesting(active == .search)
            .navigationTitle(active == .search ? "Search" : "")

            NotificationsView(embeddedInSplitView: true)
                .opacity(active == .notifications ? 1 : 0)
                .allowsHitTesting(active == .notifications)
                .navigationTitle(active == .notifications ? "Activity" : "")

            ProfileView(actorDID: nil, splitNavPath: $phoneTimelineNavPath)
                .opacity(active == .profile ? 1 : 0)
                .allowsHitTesting(active == .profile)
                .navigationTitle(active == .profile ? "Profile" : "")

            // Drawer destinations — recreated on entry, which is fine (they
            // were separate coldly-switched tabs before).
            Group {
                switch active {
                case .messages:
                    ConversationListView(embeddedInSplitView: true)
                        .navigationTitle("Messages")
                case .bookmarks:
                    BookmarksView(splitNavPath: $phoneTimelineNavPath)
                        .navigationTitle("Bookmarks")
                case .drafts:
                    DraftsView(splitNavPath: $phoneTimelineNavPath, onOpenDraft: { draft in
                        draftToResume = draft
                    })
                    .navigationTitle("Drafts")
                case .settings:
                    SettingsView()
                default:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - iPhone Bottom Bar
    // Page-aware chrome:
    //  • Tab pages: [pill] + [right circle] — Search morphs the pill into
    //    its field; the timeline adds a scroll-to-top circle while scrolled.
    //  • Messages list: [Home] + the "+" recipient button; inside a chat
    //    the bar disappears entirely (the conversation composer takes over).
    //  • Drawer-only pages (Settings, Drafts, Bookmarks, …): no bar at all —
    //    the drawer and its pinned Home row are the way around.
    @ViewBuilder
    private var phoneBottomBar: some View {
        let active = selectedItem ?? .timeline
        if phoneChrome.conversationOpen {
            // Inside a conversation the app bar contributes nothing — the
            // conversation's own safeAreaInset composer owns the bottom
            // edge (a view-local inset is the only reliable way to keep a
            // pushed screen's scroll content above its input bar).
            EmptyView()
        } else if phoneChrome.threadReply != nil {
            // Inside a thread: [Home — pops back to the timeline] on the
            // left, and the compose circle acts as "reply to this thread".
            // No scroll-to-top here; leaving restores the full pill.
            HStack(spacing: AtmoTheme.Spacing.md) {
                ThreadHomeButton {
                    selectedItem = .timeline
                    phoneTimelineNavPath = NavigationPath()
                }
                Spacer(minLength: 0)
                ComposeFAB { phoneChrome.threadReply?() }
            }
            .padding(.horizontal, AtmoTheme.Spacing.lg)
            .padding(.top, AtmoTheme.Spacing.xs)
            .padding(.bottom, AtmoTheme.Spacing.sm)
        } else if active == .messages {
            // Conversation list: [Home — back to the timeline] on the left,
            // "+" (new conversation) on the right. Inside a chat this whole
            // bar is gone (conversationOpen above) — the composer owns the
            // bottom edge there.
            HStack(spacing: AtmoTheme.Spacing.md) {
                ThreadHomeButton {
                    selectedItem = .timeline
                    phoneTimelineNavPath = NavigationPath()
                }
                Spacer(minLength: 0)
                NewDMFAB { showNewConversation = true }
            }
            .padding(.horizontal, AtmoTheme.Spacing.lg)
            .padding(.top, AtmoTheme.Spacing.xs)
            .padding(.bottom, AtmoTheme.Spacing.sm)
        } else if phoneTabItems.contains(active) {
            HStack(spacing: AtmoTheme.Spacing.md) {
                if active == .search, let searchVm = searchViewModel {
                    PhoneSearchField(viewModel: searchVm, focused: $phoneSearchFocused)
                        .transition(.blurReplace)
                } else if phoneChrome.barCollapsed {
                    // Minimized (scroll-down): a single corner button showing
                    // the current tab. Tap expands the pill; long-press offers
                    // the tabs directly via the native menu.
                    Menu {
                        ForEach(phoneTabItems) { item in
                            Button {
                                Haptics.tap()
                                selectedItem = item
                                phoneChrome.barCollapsed = false
                            } label: {
                                Label(item.rawValue, systemImage: item.icon)
                            }
                        }
                    } label: {
                        Image(systemName: active.filledIcon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(AtmoColors.accent)
                            .frame(width: 56, height: 56)
                            .glassEffect(.regular.interactive(), in: Circle())
                    } primaryAction: {
                        Haptics.tap()
                        phoneChrome.barCollapsed = false
                    }
                    .buttonStyle(.plain)
                    .transition(.blurReplace)
                    Spacer(minLength: 0)
                } else {
                    phoneTabPill
                        .transition(.blurReplace)
                    Spacer(minLength: 0)
                }

                // Right circle: Search gets a dismiss-keyboard control (the
                // field lives in this bar); everywhere else composes.
                if active == .search {
                    DismissKeyboardFAB { phoneSearchFocused = false }
                        .transition(.blurReplace)
                } else {
                    ComposeFAB { showComposer = true }
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, AtmoTheme.Spacing.lg)
            .padding(.top, AtmoTheme.Spacing.xs)
            .padding(.bottom, AtmoTheme.Spacing.sm)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: active)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: phoneChrome.barCollapsed)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: phoneChrome.timelineAtTop)
        }
    }

    private var phoneTabPill: some View {
        HStack(spacing: 2) {
            ForEach(phoneTabItems) { item in
                Button {
                    Haptics.tap()
                    // The Home button doubles as scroll control while on
                    // the timeline: scrolled → jump to top; at top with a
                    // stored return point → jump back down to it.
                    if item == .timeline, selectedItem == .timeline {
                        if !phoneChrome.timelineAtTop {
                            phoneChrome.scrollToTopRequest += 1
                        } else if phoneChrome.timelineReturnAvailable {
                            phoneChrome.scrollBackRequest += 1
                        }
                    }
                    selectedItem = item
                    phoneChrome.barCollapsed = false
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: pillIcon(for: item))
                            .font(.system(size: phoneBarShowsLabels ? 19 : 24, weight: .medium))
                            .contentTransition(.symbolEffect(.replace))
                        if phoneBarShowsLabels {
                            Text(item.rawValue)
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(selectedItem == item ? AtmoColors.accent : Color.secondary)
                    .frame(width: phoneBarShowsLabels ? 62 : 60, height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
    }

    /// Home morphs while on the timeline: up-arrow when scrolled (jump to
    /// top), down-arrow at the top with a return point stored (jump back).
    private func pillIcon(for item: SidebarItem) -> String {
        if item == .timeline, selectedItem == .timeline {
            if !phoneChrome.timelineAtTop { return "arrow.up" }
            if phoneChrome.timelineReturnAvailable { return "arrow.down" }
        }
        return selectedItem == item ? item.filledIcon : item.icon
    }
#endif

    // MARK: - Composer Dismiss Handler

    /// Called by `sheet(onDismiss:)` for every composer sheet — the FAB sheet,
    /// the draft-resume sheet, and sheets from PostActionsView.
    ///
    /// `ComposerView.onDisappear` already handles saving the draft and firing the
    /// `draftSaved` environment action in most cases. This function is a safety-net
    /// for macOS, where clicking outside the sheet window (or the system-level Cancel
    /// button) can bypass the internal `onDisappear` in edge cases.
    ///
    /// We check whether the most-recently-modified draft in DraftStore was saved
    /// within the last 2 seconds. If so, the environment action already fired and
    /// we don't need to show the toast again. If not, and the draft store grew, we
    /// show the toast here.
    private func handleComposerDismiss() {
        let store = DraftStore.shared
        guard !store.drafts.isEmpty else { return }
        let mostRecent = store.drafts[0]
        let age = Date().timeIntervalSince(mostRecent.modifiedAt)
        // If the most recent draft was modified within the last 2 seconds AND the
        // toast isn't already visible, a draft was just saved via external dismiss.
        if age < 2.0 && !showDraftSavedToast {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                showDraftSavedToast = true
            }
        }
    }

    /// URI of the custom feed the timeline currently shows (nil = Following).
    private var currentCustomFeedURI: String? {
        if case .custom(let uri, _) = timelineViewModel?.feedSource { return uri }
        return nil
    }

    /// One sidebar row per saved feed (nil = the Following timeline).
    /// Plain buttons rather than selection rows: the List's selection type
    /// is SidebarItem, and feeds switch the timeline's SOURCE instead.
    @ViewBuilder
    private func sidebarFeedRow(_ feed: CustomFeedItem?) -> some View {
        let isActive = selectedItem == .timeline && currentCustomFeedURI == feed?.uri
        Button {
            switchTimelineFeed(feed)
            selectedItem = .timeline
        } label: {
            HStack(spacing: 8) {
                if let feed {
                    AsyncCachedImage(url: feed.avatarURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(sidebarTint.opacity(0.25))
                                .overlay {
                                    Image(systemName: "square.stack")
                                        .font(.caption2)
                                        .foregroundStyle(sidebarTint)
                                }
                        }
                    }
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: isActive ? "house.fill" : "house")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(sidebarTint)
                        .frame(width: 20)
                }
                Text(feed?.displayName ?? "Home")
                    .lineLimit(1)
                    .fontWeight(isActive ? .semibold : .regular)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isActive ? sidebarTint.opacity(0.12) : nil)
    }

    /// Switches the home timeline between Following (nil) and a saved feed.
    private func switchTimelineFeed(_ feed: CustomFeedItem?) {
        let vm = getOrCreateTimelineViewModel()
        let source: TimelineViewModel.FeedSource = feed.map {
            .custom(uri: $0.uri, displayName: $0.displayName)
        } ?? .following
        Task { await vm.setFeedSource(source) }
    }

    /// Returns the persistent TimelineViewModel.
    /// If `.task` hasn't fired yet (rare edge case on macOS), creates and stores
    /// one synchronously so the same instance is always reused.
    private func getOrCreateTimelineViewModel() -> TimelineViewModel {
        if let existing = timelineViewModel { return existing }
        let vm = TimelineViewModel(service: service)
        timelineViewModel = vm   // persist so future calls and the .task both see the same instance
        return vm
    }

    /// Returns the persistent SearchViewModel, preserving query + results across tab switches.
    /// The VM's own 5-minute timer will clear results if the user is away long enough.
    private func getOrCreateSearchViewModel() -> SearchViewModel {
        if let existing = searchViewModel {
            return existing
        }
        return SearchViewModel(service: service)
    }
}

// MARK: - Liquid Glass Compose FAB
#if os(iOS)
// MARK: - Phone Side Menu
// The left drawer holding everything that isn't one of the three pill tabs.
private struct PhoneSideMenu: View {
    let active: SidebarItem?
    /// Everything the user did NOT place in the bottom bar.
    let items: [SidebarItem]
    /// URI of the custom feed the timeline currently shows (nil = Following).
    let activeFeedURI: String?
    let onSelect: (SidebarItem) -> Void
    /// A saved feed was chosen (nil = back to the Following timeline).
    let onSelectFeed: (CustomFeedItem?) -> Void

    var body: some View {
        // A rounded Liquid Glass panel spanning the full height: the glass
        // bleeds to the physical top and bottom edges (rounded corners
        // intact) while the content stays inside the safe areas.
        ZStack(alignment: .topLeading) {
            // Flush with the left screen edge, so only the trailing corners
            // round — the standard drawer profile.
            Color.clear
                .glassEffect(.regular, in: UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 36,
                    topTrailingRadius: 36,
                    style: .continuous
                ))
                .ignoresSafeArea(edges: .vertical)

            VStack(alignment: .leading, spacing: 0) {
                Text("@omic")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, AtmoTheme.Spacing.xl)
                    .padding(.top, AtmoTheme.Spacing.xl)
                    .padding(.bottom, AtmoTheme.Spacing.lg)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Pinned: always a way back to the home timeline.
                        menuRow(.timeline, isActive: active == .timeline && activeFeedURI == nil)

                        // Pinned saved feeds — the quick-switch shelf.
                        ForEach(SavedFeedsStore.shared.pinned) { feed in
                            feedRow(feed)
                        }

                        Divider()
                            .padding(.horizontal, AtmoTheme.Spacing.xl)
                            .padding(.vertical, AtmoTheme.Spacing.sm)

                        ForEach(items) { item in
                            menuRow(item)
                        }

                        // The rest of the user's saved feeds.
                        if !SavedFeedsStore.shared.unpinned.isEmpty {
                            Divider()
                                .padding(.horizontal, AtmoTheme.Spacing.xl)
                                .padding(.vertical, AtmoTheme.Spacing.sm)

                            Text("Feeds")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, AtmoTheme.Spacing.xl)
                                .padding(.bottom, AtmoTheme.Spacing.xs)

                            ForEach(SavedFeedsStore.shared.unpinned) { feed in
                                feedRow(feed)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func feedRow(_ feed: CustomFeedItem) -> some View {
        let isActive = active == .timeline && activeFeedURI == feed.uri
        Button {
            Haptics.tap()
            onSelectFeed(feed)
        } label: {
            HStack(spacing: AtmoTheme.Spacing.md) {
                AsyncCachedImage(url: feed.avatarURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AtmoColors.accent.opacity(0.25))
                            .overlay {
                                Image(systemName: "square.stack")
                                    .font(.caption)
                                    .foregroundStyle(AtmoColors.accent)
                            }
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 28)

                Text(feed.displayName)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isActive ? AtmoColors.accent : .primary)
            .padding(.horizontal, AtmoTheme.Spacing.xl)
            .padding(.vertical, AtmoTheme.Spacing.sm + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func menuRow(_ item: SidebarItem, isActive: Bool? = nil) -> some View {
        let draftCount = DraftStore.shared.drafts.count
        let rowActive = isActive ?? (active == item)
        Button {
            Haptics.tap()
            onSelect(item)
        } label: {
            HStack(spacing: AtmoTheme.Spacing.md) {
                Image(systemName: rowActive ? item.filledIcon : item.icon)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 28)
                Text(item.rawValue)
                    .font(.body.weight(rowActive ? .semibold : .regular))
                Spacer(minLength: 0)
                if item == .drafts, draftCount > 0 {
                    Text("\(draftCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            .foregroundStyle(active == item ? AtmoColors.accent : Color.primary)
            .padding(.horizontal, AtmoTheme.Spacing.xl)
            .padding(.vertical, AtmoTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Phone Search Field
// Notes-style bottom search bar. Backed by the same persistent
// SearchViewModel as SearchView, so typing here drives the page directly.
private struct PhoneSearchField: View {
    @Bindable var viewModel: SearchViewModel
    /// Hoisted to AppNavigation so the dismiss-keyboard circle can clear it.
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search Bluesky", text: $viewModel.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // Debounced fetch — same contract as SearchView's own bar:
                // fired from onChange, never the binding setter, so typing
                // doesn't rebuild the tree and drop keyboard focus.
                .onChange(of: viewModel.query) { _, newValue in
                    viewModel.onQueryChanged(newValue)
                }

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: Capsule())
        .onAppear {
            // Fresh search: pop the keyboard like Notes does. When a query
            // is already active, keep the results visible instead.
            if viewModel.query.isEmpty { focused = true }
        }
    }
}

// MARK: - Dismiss Keyboard FAB
// Takes compose's slot on the Search page only — the search field lives in
// the bottom bar there, so the circle acts as its "done" control.
private struct DismissKeyboardFAB: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AtmoColors.accent)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle().inset(by: -10))
        }
        .buttonStyle(FABButtonStyle())
        .accessibilityLabel("Dismiss Keyboard")
    }
}

// MARK: - Thread Home Button
// The bar's left side while a thread is open: a single Home pill that pops
// straight back to the timeline (the full menu returns with it).
private struct ThreadHomeButton: View {
    let action: () -> Void
    @AppStorage(PhoneBarConfig.labelsKey) private var showsLabels = false

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "house.fill")
                    .font(.system(size: showsLabels ? 19 : 24, weight: .medium))
                if showsLabels {
                    Text("Home")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(AtmoColors.accent)
            .frame(width: showsLabels ? 62 : 60, height: 56)
            .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
        .accessibilityLabel("Back to Home")
    }
}

// MARK: - New DM FAB
// Takes compose's slot on the Messages page: opens the recipient picker.
private struct NewDMFAB: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AtmoColors.accent)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.interactive(), in: Circle())
                // The bar hugs the home-indicator region — give thumb taps
                // that land just off the visible circle some forgiveness.
                .contentShape(Circle().inset(by: -10))
        }
        .buttonStyle(FABButtonStyle())
        .accessibilityLabel("New Message")
    }
}
#endif

private struct ComposeFAB: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(AtmoColors.accent)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle().inset(by: -10))
        }
        .buttonStyle(FABButtonStyle())
    }
}

private struct FABButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

// MARK: - Draft Saved Toast
// A pill-shaped confirmation that briefly appears at the bottom of the screen
// after a draft is auto-saved via swipe-to-dismiss.
private struct DraftSavedToast: View {
    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            Image(systemName: "doc.text.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AtmoColors.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("Draft saved")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Find it in Drafts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.md)
        .glassEffect(.regular, in: Capsule())
    }
}
