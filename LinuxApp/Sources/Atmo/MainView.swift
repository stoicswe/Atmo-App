import Adwaita
import Foundation
import AtmoCore

/// The window shell. Before sign-in: a login page. After: a header bar
/// (refresh / compose / account menu) over the selected pane — timeline
/// or notifications — mirroring the SwiftUI app's navigation at
/// GNOME-appropriate scale. See PORTING.md for the feature parity matrix.
struct MainView: View {

    var app: AdwaitaApp
    var window: AdwaitaWindow

    /// Which main pane is showing.
    enum Pane {
        case timeline
        case notifications
    }

    // Login form
    @State var handle = ""
    @State var appPassword = ""
    @State var twoFactorCode = ""

    // Shell
    @State var pane = Pane.timeline
    @State var composeVisible = false
    @State var composeText = ""
    @State var errorVisible = false
    @State var errorMessage = ""
    /// Bumped after every async core operation so Adwaita re-reads the
    /// model snapshots below — the models themselves aren't view state.
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
        .alertDialog(visible: $errorVisible, heading: "Something went wrong", body: errorMessage, id: "error")
        .response("OK", role: .close) { }
        .dialog(visible: $composeVisible, title: "New Post", id: "compose", width: 420, height: 320) {
            composeContent
        }
        .onAppear {
            MainLoopBridge.install()
            runCore {
                await AppSession.shared.service.restoreSession()
                if AppSession.shared.service.isAuthenticated {
                    AppSession.shared.buildViewModels()
                    await AppSession.shared.timeline?.loadInitial()
                    await AppSession.shared.notifications?.load()
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
        } end: {
            Button(icon: .custom(name: "view-refresh-symbolic")) { refreshCurrentPane() }
                .keyboardShortcut("r".ctrl())
                .tooltip("Refresh")
                .flat()
            Button(icon: .custom(name: "document-edit-symbolic")) {
                composeText = ""
                composeVisible = true
            }
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

    func refreshCurrentPane() {
        runCore {
            switch pane {
            case .timeline: await AppSession.shared.timeline?.refresh()
            case .notifications: await AppSession.shared.notifications?.load()
            }
        }
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
