import Foundation
import Observation

// MARK: - PositionStore
// Persists the user's timeline read position (top-visible post URI) to
// iCloud Key-Value Store so it syncs across all the user's devices.
//
// Setup required in Xcode (one-time):
//   Signing & Capabilities → + Capability → iCloud → check "Key-value storage"
//
// NSUbiquitousKeyValueStore:
//  • Syncs automatically when the device has network access
//  • Falls back to local-only when offline (changes merge on reconnect)
//  • 1 MB total / 1024 keys limit — well within our single-key usage
//  • No CloudKit schema or container setup required
@Observable
@MainActor
final class PositionStore {

    static let shared = PositionStore()

    // MARK: - Public State
    /// The URI of the post the user last had at the top of their timeline.
    /// Observed by TimelineView to restore scroll position on launch/device switch.
    private(set) var savedTopPostURI: String? = nil

    // MARK: - Private
    private let store = NSUbiquitousKeyValueStore.default
    private let topPostKey = "atmo.timeline.topPostURI"

    private init() {
        // Load the current value immediately
        savedTopPostURI = store.string(forKey: topPostKey)

        // Listen for changes pushed from iCloud (other devices writing)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )

        // Trigger an initial sync with iCloud
        store.synchronize()
    }

    // MARK: - Public API

    /// Persist the top-visible post URI locally and to iCloud.
    func save(topPostURI: String) {
        guard topPostURI != savedTopPostURI else { return }
        savedTopPostURI = topPostURI
        store.set(topPostURI, forKey: topPostKey)
        store.synchronize()
    }

    /// Clear the saved position (e.g. on logout).
    func clear() {
        savedTopPostURI = nil
        store.removeObject(forKey: topPostKey)
        store.synchronize()
    }

    // MARK: - iCloud change notification
    @objc private func storeDidChange(_ notification: Notification) {
        guard let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
              keys.contains(topPostKey) else { return }

        // Jump onto the main actor — we're @MainActor but the notification can arrive
        // on any thread, so we dispatch explicitly.
        Task { @MainActor in
            self.savedTopPostURI = self.store.string(forKey: self.topPostKey)
        }
    }
}
