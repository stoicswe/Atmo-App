import Foundation
import Security
import AtmoCore

/// Keychain-backed implementation of AtmoCore's `SecretsStoring`: persists
/// the user's last-used handle and the stable ATProtoKit session UUID.
///
/// The service and account keys are unchanged from earlier releases (when
/// this type was `KeychainService`) so existing installs keep their stored
/// UUID — and therefore their ATProtoKit refresh tokens — across the
/// ATProtoKit 0.34 credential-storage migration.
final class KeychainSecretsStore: SecretsStoring {

    private let service = "com.atmo.app"
    private let handleKey = "atmo.last.handle"
    private let keychainUUIDKey = "atmo.atproto.keychain.uuid"

    init() {}

    // MARK: - Handle Persistence

    func saveLastHandle(_ handle: String) {
        let data = Data(handle.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: handleKey,
            kSecValueData: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func loadLastHandle() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: handleKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clearAll() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Stable ATProtoKit Session UUID

    /// Returns the persistent UUID passed to `ATProtocolConfiguration` as its
    /// `sessionIdentifier`.
    ///
    /// On first call (i.e. first-ever launch or after `clearAll()`), a new UUID
    /// is generated and saved to the Keychain. On all subsequent launches the
    /// same UUID is returned, so ATProtoKit's refresh-token and password
    /// keychain keys (`<uuid>.refreshToken`, `<uuid>.password`) remain stable.
    func stableSessionUUID() -> UUID {
        // Try to load an existing UUID
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keychainUUIDKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let uuidString = String(data: data, encoding: .utf8),
           let uuid = UUID(uuidString: uuidString) {
            return uuid
        }

        // First launch — generate, persist, and return a new UUID
        let newUUID = UUID()
        let data = Data(newUUID.uuidString.utf8)
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keychainUUIDKey,
            kSecValueData: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        return newUUID
    }
}
