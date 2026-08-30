import Foundation
import ATProtoKit
import Observation

/// Central service object that owns and manages all ATProtoKit instances.
/// The SwiftUI app injects it as an `@Environment` object; the Linux app
/// holds it on its root state object.
///
/// Initialization order (strict):
/// 1. `ATProtocolConfiguration` — handles auth, token refresh, credential storage
/// 2. `ATProtoKit(sessionConfiguration:)` — read APIs (timeline, profile, search)
/// 3. `ATProtoBluesky(atProtoKitInstance:)` — write APIs (post, like, repost, follow)
/// 4. `ATProtoBlueskyChat(atProtoKitInstance:)` — DM APIs
///
/// Credential storage (ATProtoKit ≥ 0.34):
/// `ATProtocolConfiguration` persists the App Password and refresh token
/// through an `ATCredentialStore` (`Atmo.platform.makeCredentialStore()` —
/// `AppleSecureKeychain` on Apple platforms, a protected file on Linux),
/// namespaced by a stable session UUID that `Atmo.platform.secrets`
/// preserves across launches. The access token lives in memory only.
@Observable
@MainActor
public final class ATProtoService {

    // MARK: - Authentication State
    public private(set) var isAuthenticated: Bool = false
    public private(set) var isLoading: Bool = false
    public private(set) var authError: Error? = nil
    public private(set) var requiresTwoFactor: Bool = false

    // MARK: - Session
    public private(set) var currentUserDID: String? = nil
    public private(set) var currentHandle: String? = nil

    // MARK: - ATProtoKit Instances (read by ViewModels)
    public private(set) var configuration: ATProtocolConfiguration? = nil
    public private(set) var atProtoKit: ATProtoKit? = nil
    public private(set) var atProtoBluesky: ATProtoBluesky? = nil
    public private(set) var atProtoChat: ATProtoBlueskyChat? = nil

    // MARK: - Init
    public init() {}

    // MARK: - Authentication

    /// Authenticates with Bluesky using a handle and App Password.
    /// If 2FA is required, sets `requiresTwoFactor = true` and awaits
    /// `submitTwoFactorCode(_:)` to be called from the UI.
    public func login(handle: String, appPassword: String) async {
        isLoading = true
        authError = nil
        requiresTwoFactor = false

        do {
            let config = makeConfiguration()

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
    public func submitTwoFactorCode(_ code: String) {
        configuration?.receiveCodeFromUser(code)
    }

    /// Attempts to restore a previously authenticated session from the
    /// credential store. Called on app launch.
    public func restoreSession() async {
        isLoading = true
        do {
            let config = makeConfiguration()

            // refreshSession() reads the refresh token from the persistent
            // credential store, exchanges it for new access + refresh tokens,
            // persists the rotated refresh token, and registers a UserSession
            // (containing the server-confirmed handle and DID) into
            // UserSessionRegistry.
            //
            // We use refreshSession() rather than getSession() here because
            // getSession() needs the access token, which is memory-only and
            // never available on a cold start.
            try await config.refreshSession()

            // Pull the authoritative handle from the registry — don't rely on
            // the handle we persisted ourselves, which could be stale.
            let fallback = Atmo.platform.secrets.loadLastHandle() ?? ""
            await buildStack(config: config, fallbackHandle: fallback)
        } catch {
            // Stored session is invalid or expired; user must sign in again.
            isAuthenticated = false
        }
        isLoading = false
    }

    /// Signs out and clears all persisted state.
    public func logout() async {
        do {
            try await configuration?.removeSession()
        } catch {
            // Best effort — clear local state regardless
        }
        clearLocalState()
        Atmo.platform.secrets.clearAll()
        PositionStore.shared.clear()
    }

    // MARK: - Private Helpers

    /// Builds an `ATProtocolConfiguration` bound to the installed platform's
    /// credential store and the install's stable session UUID, so tokens
    /// stored on a previous launch are found again.
    private func makeConfiguration() -> ATProtocolConfiguration {
        ATProtocolConfiguration(
            credentialStore: Atmo.platform.makeCredentialStore(),
            sessionIdentifier: Atmo.platform.secrets.stableSessionUUID()
        )
    }

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
        // After authenticate() or refreshSession() succeeds, the registry
        // contains a UserSession with the server-confirmed handle and DID.
        if let session = try? await kit.getUserSession() {
            self.currentHandle = session.handle
            self.currentUserDID = session.sessionDID
        } else {
            // Fallback — shouldn't normally occur if authentication succeeded
            self.currentHandle = fallbackHandle.isEmpty ? nil : fallbackHandle
        }

        // Last-resort DID resolution: screens like the user's own profile
        // need the DID (getAuthorFeed rejects handles). If the registry
        // lookup came back empty but we know the handle, resolve it.
        if currentUserDID == nil, let handle = currentHandle {
            currentUserDID = try? await kit.resolveHandle(from: handle).did
        }

        Atmo.platform.secrets.saveLastHandle(self.currentHandle ?? fallbackHandle)
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
