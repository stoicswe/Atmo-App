import Foundation
import AtmoCore
#if os(iOS)
import BackgroundTasks
#elseif os(watchOS)
import WatchKit
#endif

// MARK: - BackgroundSync
// Schedules AtmoCore's BackgroundSyncEngine through each platform's
// energy-efficient mechanism — never a hand-rolled timer:
//
//   • iOS: BGAppRefreshTask. The system decides the actual run moments,
//     coalescing them with device wake-ups, charging state, and the
//     user's app-usage patterns. We re-arm the request each time the
//     app backgrounds and each time a task completes.
//   • macOS: NSBackgroundActivityScheduler. Runs while the app is open
//     (even minimized), deferred and batched by the system with a wide
//     tolerance, at utility QoS — the API macOS provides specifically
//     so periodic work doesn't defeat App Nap or timer coalescing.
//   • watchOS: WKApplication background refresh, so a standalone watch
//     (no phone nearby) still checks on its own. The system coalesces
//     these tightly — expect roughly hourly unless the app has a
//     complication on the active watch face, which raises the budget.
//
// A pass restores the session if needed (background launches skip the
// UI's restore path), runs one engine pass, and hands the resulting
// alerts to the platform presenter (local notifications).
@MainActor
enum BackgroundSync {

    static let taskIdentifier = "com.stoicswe.atmo.refresh"

    private static var engine: BackgroundSyncEngine?
    private static var service: ATProtoService?

    /// Call once, as soon as the service exists. On iOS this must happen
    /// before the app finishes launching so the task handler is
    /// registered in time.
    static func configure(service: ATProtoService) {
        guard engine == nil else { return }
        self.service = service
        engine = BackgroundSyncEngine(service: service, settings: .shared)
#if os(iOS)
        registerTaskHandler()
        scheduleNextRefresh()
#elseif os(macOS)
        startActivityScheduler()
#elseif os(watchOS)
        // Deliberately NO initial schedule here: configure runs during
        // App.init(), BEFORE the WKApplicationDelegateAdaptor installs the
        // delegate — and watchOS hard-aborts a schedule call while the
        // delegate is null ("requires that your WKApplicationDelegate
        // implement handleBackgroundTasks:"), killing the app at launch.
        // The scenePhase → .background hook arms the first request once
        // the app is fully up; each delivered task re-arms the next.
#endif
    }

    /// One battery-friendly sync pass: restore session if needed, check
    /// interactions + subscriptions, present alerts.
    static func runPass() async {
        guard let engine, let service else { return }
        if !service.isAuthenticated {
            await service.restoreSession()
        }
        guard service.isAuthenticated else { return }
        let alerts = await engine.performSyncPass()
        guard !alerts.isEmpty else { return }
        await Atmo.platform.alertPresenter.present(alerts)
    }

#if os(iOS)
    // MARK: - iOS: BGAppRefreshTask

    private static func registerTaskHandler() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task { @MainActor in
                await runPass()
                scheduleNextRefresh()
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = {
                work.cancel()
            }
        }
    }

    /// Ask for a refresh no sooner than 15 minutes out. The system picks
    /// the real moment; asking again while one is pending is harmless.
    static func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
#endif

#if os(watchOS)
    // MARK: - watchOS: WKApplication background refresh
    //
    // The task *handler* lives in WatchAppDelegate (WatchKit delivers
    // background tasks through the application delegate, not a closure
    // registry like BGTaskScheduler). This only arms the next request.

    /// Ask for a wake-up no sooner than 15 minutes out. watchOS treats
    /// this as a preference, not a promise — it batches wake-ups by
    /// wrist state, battery, and complication presence.
    static func scheduleNextRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: 15 * 60),
            userInfo: nil
        ) { _ in
            // Scheduling failures are non-actionable here; the next
            // foreground launch re-arms.
        }
    }
#endif

#if os(macOS)
    // MARK: - macOS: NSBackgroundActivityScheduler

    private static let activity = NSBackgroundActivityScheduler(identifier: taskIdentifier)

    private static func startActivityScheduler() {
        activity.repeats = true
        activity.interval = 15 * 60
        // A third of the interval as tolerance lets the system fold our
        // wake-up into ones it was doing anyway.
        activity.tolerance = 5 * 60
        activity.qualityOfService = .utility
        activity.schedule { completion in
            Task { @MainActor in
                await runPass()
                completion(.finished)
            }
        }
    }
#endif
}
