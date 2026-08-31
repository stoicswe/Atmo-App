import SwiftUI
import AtmoCore
import CoreSpotlight

@main
struct AtmoApp: App {
    @State private var atProtoService = ATProtoService()
    /// Post URI received from a Spotlight tap — propagated to AppNavigation via environment.
    @State private var spotlightPostURI: String? = nil

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Install the Apple implementations of AtmoCore's platform seams
        // (Keychain, iCloud KVS, Spotlight, lifecycle notifications) before
        // any AtmoCore service singleton is touched.
        Atmo.platform = .apple

        // Configure the shared URLCache before any image loading begins.
        // Must happen here (not in a .task or .onAppear) so the static
        // URLSession in AsyncCachedImage picks up the enlarged cache.
        URLCache.configureSharedCache()

        // Background sync (interaction + subscribed-post notifications).
        // Must be set up during launch: iOS requires the BGTaskScheduler
        // handler to be registered before the app finishes launching.
        let service = ATProtoService()
        _atProtoService = State(initialValue: service)
        BackgroundSync.configure(service: service)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(spotlightPostURI: $spotlightPostURI)
                .environment(atProtoService)
                // Appearance (auto/light/dark), accent, text size, and
                // reduce-motion — all from Settings → Appearance/Accessibility.
                .atmoTheme()
                // Handle Spotlight search result taps.
                // The system delivers a NSUserActivity with type CSSearchableItemActionType
                // and a userInfo key CSSearchableItemActivityIdentifier whose value is the
                // uniqueIdentifier we set when indexing — i.e. the post URI.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let uri = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    spotlightPostURI = uri
                }
        }
#if os(iOS)
        // Re-arm the background refresh request whenever the app leaves
        // the foreground — the system then picks battery-friendly moments
        // to run the sync passes.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                BackgroundSync.scheduleNextRefresh()
            }
        }
#endif
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
    @Environment(\.scenePhase) private var scenePhase
    /// Bound to AtmoApp.spotlightPostURI — set when a Spotlight result is tapped.
    @Binding var spotlightPostURI: String?

    var body: some View {
        Group {
            switch service.authPhase {
            case .restoring:
                // Neutral splash while the stored session refreshes. The
                // login form must not mount here: its credential fields
                // grab focus and summon the system password AutoFill
                // panel, which then lingers over the signed-in window.
                SessionRestoreView()
                    .transition(.opacity)
            case .authenticated:
                AppNavigation(spotlightPostURI: $spotlightPostURI)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .unauthenticated:
                LoginView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: service.authPhase)
        .task {
            await service.restoreSession()
        }
        // If the cold-start restore was cancelled with its scene (the
        // task above doesn't re-fire on re-activation), the app would sit
        // on the splash forever. Kick another attempt whenever the scene
        // becomes active while still in `.restoring` with none in flight.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active,
                  case .restoring = service.authPhase,
                  !service.isLoading else { return }
            Task { await service.restoreSession() }
        }
    }
}

/// Shown between launch and the outcome of the session restore — the same
/// sky backdrop and cloud mark as LoginView, minus the credential fields,
/// so both possible destinations feel like a crossfade rather than a swap.
struct SessionRestoreView: View {
    var body: some View {
        ZStack {
            AtmoColors.skyGradient
                .ignoresSafeArea()

            VStack(spacing: AtmoTheme.Spacing.md) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AtmoColors.accent, .white.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing)

                ProgressView()
                    .controlSize(.small)
            }
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
