import Foundation
import AtmoCore
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Owner verification for the bookmarks Vault: Face ID or Touch ID, with
/// the device passcode (macOS: the account password) as the fallback the
/// system offers itself. A fresh context per attempt, so a cancelled
/// prompt never leaves stale state behind.
struct LocalVaultAuthenticator: VaultAuthenticating {

    var isAvailable: Bool {
#if canImport(LocalAuthentication)
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
#else
        false
#endif
    }

    func authenticate(reason: String) async -> Bool {
#if canImport(LocalAuthentication)
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
#else
        return false
#endif
    }
}
