import Foundation
import AtmoCore

/// iCloud Key-Value Store implementation of AtmoCore's `SyncedKeyValueStore`.
///
/// NSUbiquitousKeyValueStore:
///  • Syncs automatically when the device has network access
///  • Falls back to local-only when offline (changes merge on reconnect)
///  • 1 MB total / 1024 keys limit — well within our usage
///  • Requires the iCloud key-value-storage entitlement
///    (com.apple.developer.ubiquity-kvstore-identifier, set in
///    Resources/Atmo.entitlements)
final class UbiquitousKeyValueStore: SyncedKeyValueStore, @unchecked Sendable {

    // NSUbiquitousKeyValueStore is thread-safe but predates Sendable,
    // hence the @unchecked conformance above.
    private let store = NSUbiquitousKeyValueStore.default

    init() {}

    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func string(forKey key: String) -> String? { store.string(forKey: key) }
    func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
    func set(_ string: String, forKey key: String) { store.set(string, forKey: key) }
    func removeValue(forKey key: String) { store.removeObject(forKey: key) }
    func synchronize() { store.synchronize() }

    /// Emits the batches of keys another device changed, extracted from
    /// `didChangeExternallyNotification` payloads.
    func externalChanges() -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store,
                queue: nil
            ) { notification in
                let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
                if let changedKeys, !changedKeys.isEmpty {
                    continuation.yield(changedKeys)
                }
            }
            let box = UncheckedSendableBox(token)
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(box.value)
            }
        }
    }
}

/// NotificationCenter observer tokens are safe to pass back to
/// `removeObserver` from any thread, but their type predates Sendable.
private final class UncheckedSendableBox: @unchecked Sendable {
    let value: NSObjectProtocol
    init(_ value: NSObjectProtocol) { self.value = value }
}
