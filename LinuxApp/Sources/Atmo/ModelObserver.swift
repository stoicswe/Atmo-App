import Foundation
import Observation

/// Bridges Swift Observation onto the GTK render loop.
///
/// AtmoCore's view models are `@Observable`, which SwiftUI tracks
/// automatically — Adwaita has no such integration, so before this bridge
/// the Linux UI only re-rendered after its *own* awaits (`runCore`'s tick
/// bump). Anything the models changed on their own schedule — the 60 s
/// silent timeline refresh, the search view model's debounced fetches —
/// stayed invisible until the next user interaction.
///
/// `observe` re-registers `withObservationTracking` in a loop: `read`
/// touches the properties to track, and any change fires `onChange` (the
/// shell bumps its tick there) on the main actor via the MainLoopBridge.
@MainActor
enum ModelObserver {

    /// Tracks the properties `read` touches for the rest of the session.
    /// `read` returning false stops the loop (model released).
    static func observe(
        _ read: @escaping @MainActor () -> Bool,
        onChange: @escaping @MainActor () -> Void
    ) {
        guard read() else { return }
        withObservationTracking {
            _ = read()
        } onChange: {
            // willSet fires synchronously; hop so the new values are in
            // place — and so re-registration can't recurse.
            Task { @MainActor in
                onChange()
                observe(read, onChange: onChange)
            }
        }
    }
}
