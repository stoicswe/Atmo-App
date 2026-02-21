import SwiftUI

// MARK: - Sidebar Items
enum SidebarItem: String, CaseIterable, Identifiable {
    case timeline      = "Home"
    case search        = "Search"
    case notifications = "Notifications"
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
            VStack(spacing: 0) {

                // ── Scrollable primary items ──
                List(primaryItems, selection: $selectedItem) { item in
                    sidebarLabel(for: item)
                        .tag(item)
                }
                .listStyle(.sidebar)
                .frame(maxHeight: .infinity)

                Divider()
                    .overlay(Color.secondary.opacity(0.2))

                // ── Bottom-pinned: Profile + Settings ──
                VStack(spacing: 2) {
                    ForEach(bottomItems) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            sidebarLabel(for: item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background {
                                    if selectedItem == item {
                                        RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small)
                                            .fill(Color.accentColor.opacity(0.15))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
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
                .navigationTitle(active == .notifications ? "Notifications" : "")

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
#if os(iOS)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
#endif
    }

    private func navigationTitle(for item: SidebarItem) -> String {
        switch item {
        case .timeline:      return "Home"
        case .search:        return "Search"
        case .notifications: return "Notifications"
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

    // MARK: - iPhone Tab View
#if os(iOS)
    private var phoneTabView: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedItem) {
                // Primary tabs — Timeline gets its own owned NavigationPath so
                // Spotlight deep-links can push a thread onto it from AppNavigation.
                NavigationStack(path: $phoneTimelineNavPath) {
                    detailView(for: .timeline)
                        .navigationDestination(for: PostNavTarget.self) { target in
                            ThreadView(postURI: target.uri)
                        }
                        .navigationDestination(for: String.self) { did in
                            ProfileView(actorDID: did)
                        }
                }
                .tabItem {
                    Label(SidebarItem.timeline.rawValue,
                          systemImage: selectedItem == .timeline
                          ? SidebarItem.timeline.filledIcon
                          : SidebarItem.timeline.icon)
                }
                .tag(Optional(SidebarItem.timeline))

                // Remaining primary tabs (search, notifications, messages)
                ForEach(primaryItems.filter { $0 != .timeline }) { item in
                    NavigationStack {
                        detailView(for: item)
                    }
                    .tabItem {
                        Label(item.rawValue,
                              systemImage: selectedItem == item ? item.filledIcon : item.icon)
                    }
                    .tag(Optional(item))
                }

                // Profile tab
                NavigationStack { detailView(for: .profile) }
                    .tabItem {
                        Label(SidebarItem.profile.rawValue,
                              systemImage: selectedItem == .profile
                              ? SidebarItem.profile.filledIcon
                              : SidebarItem.profile.icon)
                    }
                    .tag(Optional(SidebarItem.profile))

                // Bookmarks tab
                NavigationStack { detailView(for: .bookmarks) }
                    .tabItem {
                        Label(SidebarItem.bookmarks.rawValue,
                              systemImage: selectedItem == .bookmarks
                              ? SidebarItem.bookmarks.filledIcon
                              : SidebarItem.bookmarks.icon)
                    }
                    .tag(Optional(SidebarItem.bookmarks))

                // Settings tab
                NavigationStack { detailView(for: .settings) }
                    .tabItem {
                        Label(SidebarItem.settings.rawValue,
                              systemImage: selectedItem == .settings
                              ? SidebarItem.settings.filledIcon
                              : SidebarItem.settings.icon)
                    }
                    .tag(Optional(SidebarItem.settings))
            }

            // Liquid Glass FAB — above tab bar
            ComposeFAB { showComposer = true }
                .padding(.trailing, AtmoTheme.Spacing.xl)
                .padding(.bottom, 88)
        }
    }
#endif

    // MARK: - Detail Destination (iPhone only)
    // On iPad/macOS the persistent ZStack in `persistentDetailStack` is used instead,
    // which preserves scroll position by keeping all views alive simultaneously.
    // iPhone TabView already preserves tab state natively, so a simple switch is fine here.
    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        switch item {
        case .timeline:
            let vm = getOrCreateTimelineViewModel()
            TimelineView(viewModel: vm)
        case .search:
            let vm = getOrCreateSearchViewModel()
            SearchView(viewModel: vm)
        case .notifications:
            NotificationsView()
        case .messages:
            ConversationListView()
        case .profile:
            ProfileView(actorDID: nil)
        case .bookmarks:
            BookmarksView()
        case .drafts:
            DraftsView(onOpenDraft: { draft in
                draftToResume = draft
            })
        case .settings:
            SettingsView()
        }
    }

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
private struct ComposeFAB: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.title2.weight(.semibold))
                .foregroundStyle(AtmoColors.skyBlue)
                .frame(width: 56, height: 56)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
        }
        .buttonStyle(FABButtonStyle())
        .atmoShadow(AtmoTheme.Shadow.floating)
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
                .foregroundStyle(AtmoColors.skyBlue)

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
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .glassEffect(.regular, in: Capsule())
        }
        .clipShape(Capsule())
        .atmoShadow(AtmoTheme.Shadow.floating)
    }
}
