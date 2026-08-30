import Foundation
import Observation

// MARK: - PositionStore
// Persists the user's timeline read position (top-visible post URI) to the
// platform's synced key-value store so it follows the user across devices
// (iCloud KVS on Apple platforms; local-only elsewhere).
@Observable
@MainActor
public final class PositionStore {

    public static let shared = PositionStore()

    // MARK: - Public State
    /// The URI of the post the user last had at the top of their timeline.
    /// Observed by the timeline UI to restore scroll position on launch or
    /// device switch.
    public private(set) var savedTopPostURI: String? = nil

    // MARK: - Private
    private let store = Atmo.platform.syncedKeyValue
    private let topPostKey = "atmo.timeline.topPostURI"
    private var externalChangeTask: Task<Void, Never>? = nil

    private init() {
        // Load the current value immediately
        savedTopPostURI = store.string(forKey: topPostKey)

        // Listen for changes pushed from other devices
        startObservingRemoteChanges()

        // Trigger an initial sync with the backing service
        store.synchronize()
    }

    // MARK: - Public API

    /// Persist the top-visible post URI locally and to the synced store.
    public func save(topPostURI: String) {
        guard topPostURI != savedTopPostURI else { return }
        savedTopPostURI = topPostURI
        store.set(topPostURI, forKey: topPostKey)
        store.synchronize()
    }

    /// Clear the saved position (e.g. on logout).
    public func clear() {
        savedTopPostURI = nil
        store.removeValue(forKey: topPostKey)
        store.synchronize()
    }

    // MARK: - Remote change observation

    private func startObservingRemoteChanges() {
        let key = topPostKey
        let changes = store.externalChanges()
        externalChangeTask = Task { [weak self] in
            for await changedKeys in changes {
                guard changedKeys.contains(key) else { continue }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.savedTopPostURI = self.store.string(forKey: self.topPostKey)
                }
            }
        }
    }
}
