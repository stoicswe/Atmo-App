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
    /// Whether the home timeline is resting at its top — drives the
    /// bar's scroll-to-top circle.
    var timelineAtTop = true
    /// Incremented by the bar's scroll-to-top circle; the timeline
    /// observes it and jumps.
    var scrollToTopRequest = 0
    /// DM composer draft while a conversation owns the bottom bar.
    var dmDraft: String = ""
    /// Non-nil while a conversation is on top: the bar renders the message
    /// field + send arrow and calls this to send `dmDraft`. Registered by
    /// ConversationDetailView on appear, cleared on disappear.
    var dmSend: (@MainActor () -> Void)? = nil

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
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
#if os(iOS)
    /// iPhone: whether the left drawer menu is open.
    @State private var phoneMenuOpen = false
    /// iPhone: user-chosen bottom-bar items (comma-joined rawValues).
    @AppStorage(PhoneBarConfig.storageKey) private var phoneBarItemsRaw = PhoneBarConfig.defaultValue
    /// iPhone: recipient picker for a new DM (the "+" on the Messages page).
    @State private var showNewConversation = false
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
        platformView
            // Inject the hashtag search action into the environment so any descendant
            // (FeedItemView, ThreadView, etc.) can open Search pre-filled with a tag
            // without requiring explicit callback threading through intermediate views.
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
                Section {
                    ForEach(primaryItems) { item in
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
            }
            .listStyle(.sidebar)
            // Wide enough that "Notifications" and "Messages" don't truncate.
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .navigationTitle("Atmo")
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
                // All destinations for every tab registered once here
                .navigationDestination(for: PostNavTarget.self) { target in
                    ThreadView(postURI: target.uri)
                }
                .navigationDestination(for: String.self) { did in
                    ProfileView(actorDID: did, splitNavPath: $splitNavPath)
                }
                .navigationDestination(for: ConversationItem.self) { convo in
                    ConversationDetailView(conversation: convo)
                }
            }
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
                .navigationTitle(active == .timeline ? "Home" : "")

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
    private var phoneTabView: some View {
        ZStack(alignment: .leading) {
            // The app stays put; the drawer slides OVER it with a dimming
            // scrim (no scale/push-back — transforms on the live navigation
            // hierarchy were a recurring source of glitches).
            phoneMainShell

            if phoneMenuOpen {
                // Dimming scrim — tap anywhere outside the drawer to close.
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { phoneMenuOpen = false }
                    .transition(.opacity)

                PhoneSideMenu(active: selectedItem, items: phoneDrawerItems) { item in
                    // "Home" from the drawer means the top of the feed —
                    // jumping there also retires the scroll-to-top circle,
                    // so the bar arrives uncrowded.
                    if item == .timeline, !phoneChrome.timelineAtTop {
                        phoneChrome.scrollToTopRequest += 1
                    }
                    selectedItem = item
                    phoneMenuOpen = false
                }
                .frame(width: 290)
                .transition(.move(edge: .leading))
                .zIndex(2)
                // Swipe the drawer back toward the edge to close it.
                .gesture(
                    DragGesture().onEnded { value in
                        if value.translation.width < -40 { phoneMenuOpen = false }
                    }
                )
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: phoneMenuOpen)
        // Subtle pulse landing mid-slide as the drawer comes in.
        .onChange(of: phoneMenuOpen) { _, open in
            guard open else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                Haptics.soft()
            }
        }
        // Recipient picker for a new DM; opening a person pushes their
        // conversation onto the stack. Attached at the shell root, away
        // from the safe-area-inset chrome.
        .sheet(isPresented: $showNewConversation) {
            NewConversationView { convo in
                selectedItem = .messages
                phoneTimelineNavPath.append(convo)
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
                .navigationDestination(for: PostNavTarget.self) { target in
                    ThreadView(postURI: target.uri)
                }
                .navigationDestination(for: String.self) { did in
                    // Flat mode (shared path) — a pushed profile must NOT
                    // own a nested NavigationStack.
                    ProfileView(actorDID: did, splitNavPath: $phoneTimelineNavPath)
                }
                .navigationDestination(for: ConversationItem.self) { convo in
                    ConversationDetailView(conversation: convo)
                }
        }
        // Floating bottom bar. safeAreaInset (not overlay) so scroll content
        // gets the inset automatically and the bar rides above the keyboard.
        // Always present — inside a conversation it MORPHS into the message
        // composer rather than layering with a second input bar.
        .safeAreaInset(edge: .bottom, spacing: 0) { phoneBottomBar }
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
                .navigationTitle(active == .timeline ? "Home" : "")

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
    //  • Messages: ONLY the "+" recipient button.
    //  • Drawer-only pages (Settings, Drafts, Bookmarks, …): no bar at all —
    //    the drawer and its pinned Home row are the way around.
    @ViewBuilder
    private var phoneBottomBar: some View {
        let active = selectedItem ?? .timeline
        if phoneChrome.dmSend != nil {
            // Inside a conversation: the bar IS the message composer —
            // field where the pill sits, send arrow where compose sits.
            HStack(spacing: AtmoTheme.Spacing.md) {
                PhoneDMField(chrome: phoneChrome)
                SendDMFAB(chrome: phoneChrome)
            }
            .padding(.horizontal, AtmoTheme.Spacing.lg)
            .padding(.top, AtmoTheme.Spacing.xs)
            .padding(.bottom, AtmoTheme.Spacing.sm)
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
            HStack {
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
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(AtmoColors.accent)
                            .frame(width: 48, height: 48)
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

                // Timeline, scrolled down: the way back up lives IN the bar
                // so its tap target is unambiguous — the floating overlay
                // version kept losing touches to the feed rows beneath it.
                if active == .timeline, !phoneChrome.timelineAtTop {
                    ScrollToTopBarButton {
                        phoneChrome.scrollToTopRequest += 1
                    }
                    .transition(.blurReplace)
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
                    selectedItem = item
                    phoneChrome.barCollapsed = false
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: selectedItem == item ? item.filledIcon : item.icon)
                            .font(.system(size: 17, weight: .medium))
                        Text(item.rawValue)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selectedItem == item ? AtmoColors.accent : Color.secondary)
                    .frame(width: 58, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
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
    let onSelect: (SidebarItem) -> Void

    var body: some View {
        // A floating Liquid Glass panel: inset from the top and bottom
        // edges with rounded corners, rather than an edge-to-edge sheet.
        VStack(alignment: .leading, spacing: 0) {
            Text("Atmo")
                .font(.largeTitle.bold())
                .padding(.horizontal, AtmoTheme.Spacing.xl)
                .padding(.top, AtmoTheme.Spacing.xl)
                .padding(.bottom, AtmoTheme.Spacing.lg)

            // Pinned: always a way back to the home timeline.
            menuRow(.timeline)

            Divider()
                .padding(.horizontal, AtmoTheme.Spacing.xl)
                .padding(.vertical, AtmoTheme.Spacing.sm)

            ForEach(items) { item in
                menuRow(item)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        .padding(.leading, AtmoTheme.Spacing.sm)
        .padding(.vertical, AtmoTheme.Spacing.lg)
    }

    @ViewBuilder
    private func menuRow(_ item: SidebarItem) -> some View {
        let draftCount = DraftStore.shared.drafts.count
        Button {
            Haptics.tap()
            onSelect(item)
        } label: {
            HStack(spacing: AtmoTheme.Spacing.md) {
                Image(systemName: active == item ? item.filledIcon : item.icon)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 28)
                Text(item.rawValue)
                    .font(.body.weight(active == item ? .semibold : .regular))
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
                .frame(width: 56, height: 56)
                .glassEffect(.regular.interactive(), in: Circle())
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

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "house.fill")
                    .font(.system(size: 17, weight: .medium))
                Text("Home")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(AtmoColors.accent)
            .frame(width: 58, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
        .accessibilityLabel("Back to Home")
    }
}

// MARK: - Phone DM Composer (in-bar)
// The message field the bottom bar morphs into inside a conversation.
private struct PhoneDMField: View {
    @Bindable var chrome: PhoneChromeState
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Message…", text: $chrome.dmDraft, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($focused)
            .lineLimit(1...4)
            .padding(.horizontal, AtmoTheme.Spacing.lg)
            .padding(.vertical, AtmoTheme.Spacing.sm)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: RoundedRectangle(
                cornerRadius: AtmoTheme.CornerRadius.pill, style: .continuous))
            .onAppear { focused = true }
    }
}

/// Send arrow beside the DM field — up arrow, accent when there's content.
private struct SendDMFAB: View {
    @Bindable var chrome: PhoneChromeState

    private var canSend: Bool {
        !chrome.dmDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button {
            Haptics.tap()
            chrome.dmSend?()
        } label: {
            Image(systemName: "arrow.up")
                .font(.title3.weight(.semibold))
                .foregroundStyle(canSend ? AtmoColors.accent : Color.secondary)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(FABButtonStyle())
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }
}

// MARK: - Scroll To Top Bar Button
// Lives in the bottom bar next to compose while the timeline is scrolled —
// a floating overlay version kept losing touches to the feed rows.
private struct ScrollToTopBarButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AtmoColors.accent)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(FABButtonStyle())
        .accessibilityLabel("Scroll to Top")
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
                .font(.title2.weight(.semibold))
                .foregroundStyle(AtmoColors.accent)
                .frame(width: 56, height: 56)
                .glassEffect(.regular.interactive(), in: Circle())
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
                .font(.title2.weight(.semibold))
                .foregroundStyle(AtmoColors.accent)
                .frame(width: 56, height: 56)
                .glassEffect(.regular.interactive(), in: Circle())
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
