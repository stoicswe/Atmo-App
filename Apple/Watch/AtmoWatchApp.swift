import SwiftUI
import WatchKit
import AtmoCore

// The watchOS experience: a compact, read-and-react client that also
// works fully standalone — it signs in with its own Keychain session,
// talks to Bluesky over the watch's Wi-Fi/LTE, and runs its own
// background sync for notifications when no iPhone is around.
// Composing, DMs, search, and the full design system stay on the
// bigger screens. Everything below runs on the same AtmoCore services
// as the other platforms.
@main
struct AtmoWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var atProtoService: ATProtoService

    init() {
        // Install the Apple implementations of AtmoCore's platform seams
        // before any AtmoCore service singleton is touched. On watchOS the
        // Spotlight seam resolves to the no-op indexer and storage is
        // local-only (no iCloud entitlement — see project.yml).
        Atmo.platform = .apple

        // Standalone background sync: the watch schedules its own
        // WKApplication background refreshes and presents local
        // notifications, so interactions arrive without a paired phone.
        let service = ATProtoService()
        _atProtoService = State(initialValue: service)
        BackgroundSync.configure(service: service)
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(atProtoService)
        }
        // Re-arm the refresh request whenever the app leaves the
        // foreground — the system then picks battery-friendly moments.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                BackgroundSync.scheduleNextRefresh()
            }
        }
    }
}

// MARK: - Application Delegate
// WatchKit delivers background tasks through the application delegate
// (there is no closure-registration API like iOS's BGTaskScheduler).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                Task { @MainActor in
                    await BackgroundSync.runPass()
                    BackgroundSync.scheduleNextRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else {
                // Snapshot/connectivity/URLSession tasks we don't use yet.
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

// MARK: - Auth Gate
struct WatchRootView: View {
    @Environment(ATProtoService.self) private var service
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if service.isAuthenticated {
                WatchHomeView()
            } else {
                WatchLoginView()
            }
        }
        .task {
            await service.restoreSession()
        }
        // A wrist-down during the cold-start restore cancels it with the
        // scene, stranding a signed-in user at the login screen. When the
        // app comes back active and a previous session is on record, try
        // the restore again instead.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active,
                  !service.isAuthenticated,
                  !service.isLoading,
                  Atmo.platform.secrets.loadLastHandle() != nil else { return }
            Task { await service.restoreSession() }
        }
    }
}

// MARK: - Home Tabs
struct WatchHomeView: View {
    var body: some View {
        TabView {
            NavigationStack {
                WatchTimelineView()
                    .navigationTitle("Timeline")
            }
            NavigationStack {
                WatchNotificationsView()
                    .navigationTitle("Activity")
            }
            NavigationStack {
                WatchSettingsView()
                    .navigationTitle("Settings")
            }
        }
        .tabViewStyle(.verticalPage)
    }
}
