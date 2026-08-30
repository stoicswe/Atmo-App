import Adwaita
import Foundation

/// GLib ↔ Swift-concurrency bridge.
///
/// AtmoCore's services and view models are `@MainActor` and `async`
/// (network calls). On Linux, `@MainActor` jobs land on the dispatch main
/// queue — which is normally drained by `RunLoop.main` / `dispatchMain()`.
/// But in a GTK app, `g_application_run` owns the main thread with GLib's
/// main loop, so those jobs would never run and every `await` on a
/// MainActor method would hang.
///
/// The bridge installs a repeating GLib timeout that gives Foundation's
/// main RunLoop a zero-length pass on every tick. corelibs-foundation
/// integrates the dispatch main queue into CFRunLoop, so each pass drains
/// pending MainActor jobs — `Task { @MainActor in … }` then behaves
/// normally, and every continuation resumes on the GTK main thread, where
/// touching Adwaita `@State` is safe.
///
/// The 10 ms tick is imperceptible for UI work and costs ~nothing while
/// the queue is empty. Replace with a custom main-actor executor once
/// Swift's custom-executor support for the main actor is stable.
enum MainLoopBridge {

    private static var installed = false

    /// Install the pump. Call once, before the first `Task { @MainActor }`.
    static func install() {
        guard !installed else { return }
        installed = true
        Idle(delay: 10) {
            RunLoop.main.run(until: Date())
            return true // keep the timeout source alive
        }
    }
}
