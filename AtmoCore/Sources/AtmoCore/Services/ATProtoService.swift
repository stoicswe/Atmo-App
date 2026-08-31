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
/// Where the app is in its authentication lifecycle. Distinguishing
/// `.restoring` from `.unauthenticated` lets the UI hold a neutral splash
/// during the cold-start token refresh instead of flashing the login form
/// — whose credential fields would summon the system password-manager
/// AutoFill panel even though the user is about to land signed in.
public enum AuthPhase: Sendable {
    /// A previously stored session may exist and is being restored.
    case restoring
    /// A session is live; the signed-in UI should show.
    case authenticated
    /// No usable stored session; the login form should show.
    case unauthenticated
}

@Observable
@MainActor
public final class ATProtoService {

    // MARK: - Authentication State
    /// Starts at `.restoring`: every launch begins with a session-restore
    /// attempt, and the login UI must not appear until it has failed.
    public private(set) var authPhase: AuthPhase = .restoring
    public var isAuthenticated: Bool {
        if case .authenticated = authPhase { return true }
        return false
    }
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
            authPhase = .unauthenticated
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
        // Reentrancy guard: launch paths can overlap (auth-gate task,
        // scene re-activation, background sync). A second concurrent
        // refresh would race the refresh-token rotation and kill the
        // stored session. MainActor + setting isLoading before the first
        // await makes this check race-free.
        guard !isLoading else { return }
        isLoading = true
        authPhase = .restoring

        // Nothing has ever been stored on this install (or the user signed
        // out, which clears the secrets store) — go straight to the login
        // form instead of burning a doomed refresh round-trip.
        guard Atmo.platform.secrets.loadLastHandle() != nil else {
            authPhase = .unauthenticated
            isLoading = false
            return
        }

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
            // Stored session is invalid or expired; user must sign in
            // again — unless the restore was cancelled with its scene
            // (wrist-down or window close during a cold start). Then the
            // outcome is unknown: stay in `.restoring` so the UI keeps
            // its splash and a re-activation can run another attempt.
            if !Task.isCancelled && !(error is CancellationError) {
                authPhase = .unauthenticated
            }
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
        self.authPhase = .authenticated

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
        authPhase = .unauthenticated
        authError = nil
        requiresTwoFactor = false
    }
}
