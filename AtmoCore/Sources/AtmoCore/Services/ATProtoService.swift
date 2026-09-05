import Foundation
import ATProtoKit
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    /// Credentials held between the first sign-in attempt and the emailed
    /// two-factor code; cleared once a session is installed or cancelled.
    private struct PendingLogin {
        let handle: String
        let password: String
        let pdsURL: URL
    }
    @ObservationIgnored private var pendingLogin: PendingLogin? = nil

    /// Compatibility entry point (watch, Linux): resolves the PDS itself.
    public func login(handle: String, appPassword: String) async {
        await login(handle: handle, password: appPassword, pdsURL: nil)
    }

    /// Signs in with a handle (or email) and either the account password
    /// or an App Password.
    ///
    /// The session is created against the account's own PDS — `pdsURL`
    /// when the UI already resolved it, otherwise resolved here, falling
    /// back to bsky.social. With the account password on a 2FA-enabled
    /// account the server emails a code and answers
    /// `AuthFactorTokenRequired`: `requiresTwoFactor` flips on, the
    /// credentials are held, and `verifyTwoFactorCode(_:)` finishes the
    /// sign-in. App Passwords never trigger 2FA.
    public func login(handle: String, password: String, pdsURL: URL? = nil) async {
        isLoading = true
        authError = nil
        requiresTwoFactor = false
        pendingLogin = nil

        let pds: URL
        if let pdsURL {
            pds = pdsURL
        } else if let resolved = try? await PDSResolver.resolve(handle: handle) {
            pds = resolved
        } else {
            pds = PDSResolver.defaultPDS
        }

        await attemptSession(handle: handle, password: password, pdsURL: pds, token: nil)
        isLoading = false
    }

    /// Finishes a sign-in that stopped at two-factor: retries session
    /// creation with the emailed code. A rejected code keeps the 2FA
    /// step up with `authError` set, so the person can try again.
    public func verifyTwoFactorCode(_ code: String) async {
        guard let pending = pendingLogin else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        authError = nil
        await attemptSession(
            handle: pending.handle,
            password: pending.password,
            pdsURL: pending.pdsURL,
            token: trimmed
        )
        isLoading = false
    }

    /// Fire-and-forget form of `verifyTwoFactorCode(_:)` for callers
    /// without an async context (watch, Linux).
    public func submitTwoFactorCode(_ code: String) {
        Task { await verifyTwoFactorCode(code) }
    }

    /// Abandons a sign-in waiting on its two-factor code.
    public func cancelTwoFactor() {
        pendingLogin = nil
        requiresTwoFactor = false
        authError = nil
        authPhase = .unauthenticated
    }

    /// One `createSession` round-trip, with or without a 2FA token, and
    /// the session install on success.
    private func attemptSession(handle: String, password: String, pdsURL: URL, token: String?) async {
        do {
            let kit = await ATProtoKit(
                apiClientConfiguration: .init(urlSessionConfiguration: Self.makeURLSessionConfiguration()),
                pdsURL: pdsURL.absoluteString,
                canUseBlueskyRecords: false
            )
            let output = try await kit.createSession(
                with: handle,
                and: password,
                authenticationFactorToken: token
            )
            try await installSession(output, pdsURL: pdsURL)
            pendingLogin = nil
            requiresTwoFactor = false
        } catch {
            authPhase = .unauthenticated
            if Self.isTwoFactorRequired(error) || token != nil {
                // First pass: the server just emailed the code — hold the
                // credentials and ask for it. Retry pass: the code was
                // rejected — stay on the 2FA step and show why.
                pendingLogin = PendingLogin(handle: handle, password: password, pdsURL: pdsURL)
                requiresTwoFactor = true
                if token != nil { authError = error }
            } else {
                authError = error
            }
        }
    }

    /// Hands a session we created ourselves to ATProtoKit: the refresh
    /// token is stored under the exact key and encoding the library uses
    /// (`<session uuid>.refreshToken`, UTF-8 — the auth invariant in
    /// CLAUDE.md), then `refreshSession()` exchanges it and registers the
    /// user session the same way a cold-start restore does.
    private func installSession(
        _ output: ComAtprotoLexicon.Server.CreateSessionOutput,
        pdsURL: URL
    ) async throws {
        let store = Atmo.platform.makeCredentialStore()
        let uuid = Atmo.platform.secrets.stableSessionUUID()
        try await store.saveValue(
            Data(output.refreshToken.utf8),
            forKey: "\(uuid.uuidString).refreshToken"
        )
        PDSStore.save(pdsURL)
        let config = makeConfiguration()
        try await config.refreshSession()
        await buildStack(config: config, fallbackHandle: output.handle)
    }

    /// The server's "email a code first" answer, in either of the HTTP
    /// statuses PDS implementations use for it.
    nonisolated static func isTwoFactorRequired(_ error: Error) -> Bool {
        guard let apiError = error as? ATAPIError else { return false }
        switch apiError {
        case .badRequest(let response):
            return isTwoFactorRequired(code: response.error)
        case .unauthorized(let response, _):
            return isTwoFactorRequired(code: response.error)
        default:
            return false
        }
    }

    nonisolated static func isTwoFactorRequired(code: String) -> Bool {
        code == "AuthFactorTokenRequired"
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
                // Before surfacing the login form, try the stored App
                // Password: ATProtoKit persists it (for its own expiry
                // re-auth), but a refresh token invalidated by a rotation
                // race — e.g. the app killed mid-refresh — bypasses that
                // path and used to force a manual re-login.
                isLoading = false
                if await reauthenticateFromStoredCredential() { return }
                authPhase = .unauthenticated
            }
        }
        isLoading = false
    }

    /// Re-login with the credential ATProtoKit saved at authentication.
    /// Tries the current session UUID's namespace first, then — when the
    /// store can enumerate — any other stored password (the stable UUID
    /// can rotate away from the namespace the credential was written
    /// under, orphaning it). A successful login re-saves everything under
    /// the current namespace, so the store self-heals.
    /// Returns true when a session was established.
    private func reauthenticateFromStoredCredential() async -> Bool {
        guard let handle = Atmo.platform.secrets.loadLastHandle() else { return false }
        let store = Atmo.platform.makeCredentialStore()
        var keys = ["\(Atmo.platform.secrets.stableSessionUUID()).password"]
        if let enumerable = store as? EnumerableCredentialStore,
           let stored = try? await enumerable.allKeys() {
            keys += stored.filter { $0.hasSuffix(".password") && !keys.contains($0) }
        }
        for key in keys {
            guard let data = try? await store.loadValue(forKey: key),
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else { continue }
            await login(handle: handle, appPassword: password)
            if isAuthenticated { return true }
        }
        return false
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
        PDSStore.clear()
        AccountProfileCache.shared.clear()
        PositionStore.shared.clear()
    }

    /// The PDS the stored session talks to (bsky.social until an
    /// account-specific host is remembered at sign-in). Read-only; for
    /// display in settings.
    public var pdsURL: URL {
        PDSStore.load() ?? PDSResolver.defaultPDS
    }

    // MARK: - Private Helpers

    /// Builds an `ATProtocolConfiguration` bound to the installed platform's
    /// credential store and the install's stable session UUID, so tokens
    /// stored on a previous launch are found again.
    ///
    /// On Linux, requests are routed through one immortal `URLSession`
    /// (see `LinuxSharedSessionURLProtocol`) — ATProtoKit's session
    /// methods build throwaway sessions whose deallocation crashes
    /// corelibs-foundation mid-teardown.
    private func makeConfiguration() -> ATProtocolConfiguration {
        // The stored session's own PDS; bsky.social for installs that
        // signed in before the host was remembered.
        let pdsURL = (PDSStore.load() ?? PDSResolver.defaultPDS).absoluteString
        return ATProtocolConfiguration(
            pdsURL: pdsURL,
            credentialStore: Atmo.platform.makeCredentialStore(),
            sessionIdentifier: Atmo.platform.secrets.stableSessionUUID(),
            configuration: Self.makeURLSessionConfiguration()
        )
    }

    /// The `URLSessionConfiguration` every ATProtoKit instance we build
    /// (retained or one-shot) must use. On Linux it carries the
    /// shared-session `URLProtocol` so no throwaway kit ever opens a curl
    /// socket of its own; elsewhere it is the plain default.
    nonisolated static func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let sessionConfiguration = URLSessionConfiguration.default
        #if canImport(FoundationNetworking)
        sessionConfiguration.protocolClasses = [LinuxSharedSessionURLProtocol.self]
        #endif
        return sessionConfiguration
    }

    private func buildStack(config: ATProtocolConfiguration, fallbackHandle: String) async {
        #if canImport(FoundationNetworking)
        // See LinuxRequestAuthenticator: corelibs drops ATProtoKit's
        // per-request "needs session" marker, so decide it ourselves.
        let kit = await ATProtoKit(
            sessionConfiguration: config,
            apiClientConfiguration: APIClientConfiguration(
                urlSessionConfiguration: Self.makeURLSessionConfiguration(),
                requestAuthenticator: LinuxRequestAuthenticator(session: config)
            )
        )
        #else
        let kit = await ATProtoKit(sessionConfiguration: config)
        #endif
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

        // Ghost posts past their time come down as soon as we're signed in,
        // and again on every return to the foreground.
        GhostPostStore.shared.attach(service: self)
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
        pendingLogin = nil
    }
}
