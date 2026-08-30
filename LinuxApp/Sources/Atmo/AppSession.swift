import Foundation
import AtmoCore

/// GTK dispatches every callback on the main thread; AtmoCore's service
/// and view-model classes are `@MainActor`. This bridges the toolkit's
/// nonisolated view context onto that guarantee for *synchronous* reads.
/// Async work goes through `Task { @MainActor in … }` instead, which the
/// MainLoopBridge keeps running.
func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    try MainActor.assumeIsolated(body)
}

/// Owns the AtmoCore service stack for the window. Adwaita's `@State`
/// holds value snapshots only, so the reference-typed models live here
/// and the views read them through `onMain`.
@MainActor
final class AppSession {
    static let shared = AppSession()

    let service: ATProtoService
    private(set) var timeline: TimelineViewModel?
    private(set) var notifications: NotificationsViewModel?

    private init() {
        // Swap in a libsecret-backed SecretsStoring implementation when
        // one lands; the file store keeps 0600-permission JSON under
        // ~/.local/share (see FileCredentialStore) and UserDefaults on
        // Linux writes ~/.config-style plists via corelibs-foundation.
        Atmo.platform = AtmoPlatform(
            makeCredentialStore: { FileCredentialStore() },
            timelineRefreshInterval: 60
        )
        service = ATProtoService()
    }

    /// Build the per-session view models after authentication succeeds.
    func buildViewModels() {
        guard timeline == nil else { return }
        timeline = TimelineViewModel(service: service)
        notifications = NotificationsViewModel(service: service)
    }

    /// Tear down after logout.
    func reset() {
        timeline = nil
        notifications = nil
    }
}
