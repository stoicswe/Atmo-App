import Foundation
import ATProtoKit
import Observation

/// Central service object that owns and manages all ATProtoKit instances.
/// Injected as an `@Environment` object from `AtmoApp` to the entire view hierarchy.
///
/// Initialization order (strict):
/// 1. `ATProtocolConfiguration` — handles auth, token refresh, keychain storage
/// 2. `ATProtoKit(sessionConfiguration:)` — read APIs (timeline, profile, search)
/// 3. `ATProtoBluesky(atProtoKitInstance:)` — write APIs (post, like, repost, follow)
/// 4. `ATProtoBlueskyChat(atProtoKitInstance:)` — DM APIs
@Observable
@MainActor
final class ATProtoService {

    // MARK: - Authentication State
    private(set) var isAuthenticated: Bool = false
    private(set) var isLoading: Bool = false
    private(set) var authError: Error? = nil
    private(set) var requiresTwoFactor: Bool = false

    // MARK: - Session
    private(set) var currentUserDID: String? = nil
    private(set) var currentHandle: String? = nil

    // MARK: - ATProtoKit Instances (internal access for ViewModels)
    private(set) var configuration: ATProtocolConfiguration? = nil
    private(set) var atProtoKit: ATProtoKit? = nil
    private(set) var atProtoBluesky: ATProtoBluesky? = nil
    private(set) var atProtoChat: ATProtoBlueskyChat? = nil

    // MARK: - Init
    init() {}

    // MARK: - Authentication

    /// Authenticates with Bluesky using a handle and App Password.
    /// If 2FA is required, sets `requiresTwoFactor = true` and awaits
    /// `submitTwoFactorCode(_:)` to be called from the UI.
    func login(handle: String, appPassword: String) async {
        isLoading = true
        authError = nil
        requiresTwoFactor = false

        do {
            // Use a stable keychain UUID so tokens persist reliably across launches.
            let stableUUID = KeychainService.shared.stableKeychainUUID()
            let keychain = AppleSecureKeychain(identifier: stableUUID)
            let config = ATProtocolConfiguration(keychainProtocol: keychain)

            // authenticate() may internally pause awaiting a 2FA code.
            // We surface this to the UI by listening to the needsCode callback.
            try await config.authenticate(with: handle, password: appPassword)

            await buildStack(config: config, fallbackHandle: handle)
        } catch {
            authError = error
        }

        isLoading = false
    }

    /// Submits a 2FA code when the authentication flow requires it.
    func submitTwoFactorCode(_ code: String) {
        configuration?.receiveCodeFromUser(code)
    }

    /// Attempts to restore a previously authenticated session from Keychain.
    /// Called on app launch from `AtmoApp`.
    func restoreSession() async {
        isLoading = true
        do {
            // Use the SAME stable UUID that was used at login time.
            // This ensures ATProtoKit reads refresh/access tokens from the correct
            // keychain slot rather than looking under a fresh random UUID.
            let stableUUID = KeychainService.shared.stableKeychainUUID()
            let keychain = AppleSecureKeychain(identifier: stableUUID)
            let config = ATProtocolConfiguration(keychainProtocol: keychain)

            // refreshSession() reads the refresh token from the on-disk keychain
            // (not just in-memory), exchanges it for new access + refresh tokens,
            // persists those back to the keychain, and registers a UserSession
            // (containing the server-confirmed handle and DID) into UserSessionRegistry.
            //
            // We use refreshSession() rather than getSession() here because
            // getSession() needs the access token in memory (only cached there),
            // which is never available on a cold-start.
            try await config.refreshSession()

            // Pull the authoritative handle from the registry — don't rely on
            // the handle we saved to our own Keychain which could be stale.
            let fallback = KeychainService.shared.loadLastHandle() ?? ""
            await buildStack(config: config, fallbackHandle: fallback)
        } catch {
            // Stored session is invalid or expired; user must sign in again.
            isAuthenticated = false
        }
        isLoading = false
    }

    /// Signs out and clears all persisted state.
    func logout() async {
        do {
            try await configuration?.deleteSession()
        } catch {
            // Best effort — clear local state regardless
        }
        clearLocalState()
        KeychainService.shared.clearAll()
        PositionStore.shared.clear()
    }

    // MARK: - Private Helpers

    private func buildStack(config: ATProtocolConfiguration, fallbackHandle: String) async {
        let kit = await ATProtoKit(sessionConfiguration: config)
        let bluesky = ATProtoBluesky(atProtoKitInstance: kit)
        let chat = ATProtoBlueskyChat(atProtoKitInstance: kit)

        self.configuration = config
        self.atProtoKit = kit
        self.atProtoBluesky = bluesky
        self.atProtoChat = chat
        self.isAuthenticated = true

        // Pull the authoritative handle and DID from the UserSessionRegistry.
        // After authenticate() or getSession() succeeds, the registry contains
        // a UserSession with the server-confirmed handle and DID.
        if let session = try? await kit.getUserSession() {
            self.currentHandle = session.handle
            self.currentUserDID = session.sessionDID
        } else {
            // Fallback — shouldn't normally occur if authenticate/getSession succeeded
            self.currentHandle = fallbackHandle.isEmpty ? nil : fallbackHandle
        }

        KeychainService.shared.saveLastHandle(self.currentHandle ?? fallbackHandle)
    }

    private func clearLocalState() {
        configuration = nil
        atProtoKit = nil
        atProtoBluesky = nil
        atProtoChat = nil
        currentUserDID = nil
        currentHandle = nil
        isAuthenticated = false
        authError = nil
        requiresTwoFactor = false
    }
}
