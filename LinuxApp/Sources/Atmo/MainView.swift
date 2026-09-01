import Adwaita
import Foundation
import AtmoCore

/// The window shell. Before sign-in: a login page. After: a header bar
/// (panes / refresh / compose / account menu) over the selected pane —
/// timeline, notifications, or search — with thread pages pushed onto an
/// `AdwNavigationView`, mirroring the SwiftUI app's navigation at
/// GNOME-appropriate scale. See PORTING.md for the feature parity matrix.
struct MainView: View {

    var app: AdwaitaApp
    var window: AdwaitaWindow

    /// Which main pane is showing.
    enum Pane {
        case timeline
        case notifications
        case search
    }

    /// A pushed thread page (the navigation component).
    struct ThreadRoute: CustomStringConvertible, Equatable {
        let uri: String
        var description: String { "Thread" }
    }

    // Login form
    @State var handle = ""
    @State var appPassword = ""
    @State var twoFactorCode = ""

    // Shell
    @State var pane = Pane.timeline
    @State var navStack = NavigationStack<ThreadRoute>()
    @State var composeVisible = false
    @State var composeText = ""
    /// Non-nil while the compose dialog is a reply — the value snapshot of
    /// the post being replied to (handed to ComposerViewModel on submit).
    @State var composeReplyTo: PostItem? = nil
    @State var errorVisible = false
    @State var errorMessage = ""
    // Search pane
    @State var searchQuery = ""
    @State var searchCategory = SearchCategory.posts.rawValue
    // Thread pages (one entry visible at a time; cleared on send)
    @State var threadReplyText = ""
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

    // MARK: - Body

    var view: Body {
        NavigationView($navStack, "@omic") { route in
            threadPage(route)
                .topToolbar {
                    // Empty AdwHeaderBar: the navigation view supplies the
                    // back button and the route's title.
                    HeaderBar.empty()
                }
        } initialView: {
            VStack {
                if isAuthenticated {
                    homePane
                } else {
                    loginPage
                }
            }
            .topToolbar(visible: isAuthenticated) {
                headerBar
            }
        }
        .alertDialog(visible: $errorVisible, heading: "Something went wrong", body: errorMessage, id: "error")
        .response("OK", role: .close) { }
        .dialog(
            visible: $composeVisible,
            title: composeReplyTo == nil ? "New Post" : "Reply",
            id: "compose",
            width: 420,
            height: 320
        ) {
            composeContent
        }
        .onAppear {
            MainLoopBridge.install()
            onMain { ImageLoader.shared.onUpdate = { tick += 1 } }
            runCore {
                await AppSession.shared.service.restoreSession()
                if AppSession.shared.service.isAuthenticated {
                    startSignedInSession()
                }
            }
        }
    }

    // MARK: - Header bar

    @ViewBuilder var headerBar: Body {
        HeaderBar {
            Button(icon: .custom(name: "view-list-symbolic")) { pane = .timeline }
                .tooltip("Timeline")
                .flat()
            Button(icon: .custom(name: "preferences-system-notifications-symbolic")) { pane = .notifications }
                .tooltip("Notifications")
                .flat()
            Button(icon: .custom(name: "system-search-symbolic")) { pane = .search }
                .keyboardShortcut("f".ctrl())
                .tooltip("Search")
                .flat()
        } end: {
            Button(icon: .custom(name: "view-refresh-symbolic")) { refreshCurrentPane() }
                .keyboardShortcut("r".ctrl())
                .tooltip("Refresh")
                .flat()
            Button(icon: .custom(name: "document-edit-symbolic")) { openComposer(replyTo: nil) }
                .keyboardShortcut("n".ctrl())
                .tooltip("New Post")
                .flat()
            Menu(icon: .custom(name: "open-menu-symbolic")) {
                MenuButton("Sign Out (@\(currentHandle))") { signOut() }
            }
            .primary()
            .tooltip("Account")
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
            await AppSession.shared.timeline?.loadInitial()
            await AppSession.shared.notifications?.load()
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
                  let search = AppSession.shared.search else { return false }
            _ = timeline.posts
            _ = timeline.isLoading
            _ = notifications.notifications
            _ = search.postResults
            _ = search.peopleResults
            _ = search.hashtagResults
            _ = search.isLoading
            return true
        } onChange: {
            tick += 1
        }
    }

    func refreshCurrentPane() {
        runCore {
            switch pane {
            case .timeline: await AppSession.shared.timeline?.refresh()
            case .notifications: await AppSession.shared.notifications?.load()
            case .search:
                AppSession.shared.search?.onQueryChanged(searchQuery)
            }
        }
    }

    /// Pushes a thread page for the given post and starts loading it.
    func openThread(uri: String) {
        navStack.push(ThreadRoute(uri: uri))
        runCore {
            let session = AppSession.shared.threadSession(for: uri)
            await session.thread.load()
            session.interactions.seedPosts(session.thread.allPosts)
        }
    }

    func openComposer(replyTo: PostItem?) {
        composeText = ""
        composeReplyTo = replyTo
        composeVisible = true
    }

    func signOut() {
        runCore {
            await AppSession.shared.service.logout()
            AppSession.shared.reset()
        }
    }

    func presentError(_ message: String) {
        errorMessage = message
        errorVisible = true
    }
}
