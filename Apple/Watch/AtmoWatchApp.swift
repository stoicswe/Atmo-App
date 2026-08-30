import SwiftUI
import AtmoCore

// The watchOS companion experience: a compact, read-and-react client.
// Timeline and notifications with like/repost — composing, DMs, search,
// and the full design system stay on the bigger screens. Everything below
// runs on the same AtmoCore services as the other platforms.
@main
struct AtmoWatchApp: App {
    @State private var atProtoService = ATProtoService()

    init() {
        // Install the Apple implementations of AtmoCore's platform seams
        // before any AtmoCore service singleton is touched. On watchOS the
        // Spotlight seam resolves to the no-op indexer automatically.
        Atmo.platform = .apple
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(atProtoService)
        }
    }
}

// MARK: - Auth Gate
struct WatchRootView: View {
    @Environment(ATProtoService.self) private var service

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
        }
        .tabViewStyle(.verticalPage)
    }
}
