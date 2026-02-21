import SwiftUI
import CoreSpotlight

@main
struct AtmoApp: App {
    @State private var atProtoService = ATProtoService()
    /// Post URI received from a Spotlight tap — propagated to AppNavigation via environment.
    @State private var spotlightPostURI: String? = nil

    init() {
        // Configure the shared URLCache before any image loading begins.
        // Must happen here (not in a .task or .onAppear) so the static
        // URLSession in AsyncCachedImage picks up the enlarged cache.
        URLCache.configureSharedCache()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(spotlightPostURI: $spotlightPostURI)
                .environment(atProtoService)
                .atmoTint()
                // Handle Spotlight search result taps.
                // The system delivers a NSUserActivity with type CSSearchableItemActionType
                // and a userInfo key CSSearchableItemActivityIdentifier whose value is the
                // uniqueIdentifier we set when indexing — i.e. the post URI.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let uri = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    spotlightPostURI = uri
                }
        }
#if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 760)
        .commands {
            AtmoCommands()
        }
#endif
    }
}

// MARK: - Auth Gate
struct ContentView: View {
    @Environment(ATProtoService.self) private var service
    /// Bound to AtmoApp.spotlightPostURI — set when a Spotlight result is tapped.
    @Binding var spotlightPostURI: String?

    var body: some View {
        Group {
            if service.isAuthenticated {
                AppNavigation(spotlightPostURI: $spotlightPostURI)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: service.isAuthenticated)
        .task {
            await service.restoreSession()
        }
    }
}

// MARK: - macOS Menu Commands
#if os(macOS)
struct AtmoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Compose shortcut handled in-app
        }
    }
}
#endif
