import Foundation
import Observation

@Observable
@MainActor
public final class AuthViewModel {
    public init() {}

    public var handle: String = ""
    /// The account password or an App Password — both sign in; only the
    /// account password can prompt for a two-factor code.
    public var appPassword: String = ""
    public var twoFactorCode: String = ""

    /// Hosting service resolved for the typed handle, refreshed as the
    /// person types (debounced). Nil until resolved; the default host is
    /// used when resolution fails or the identifier is an email.
    public private(set) var resolvedPDS: URL? = nil
    public private(set) var isResolvingPDS: Bool = false
    /// The last resolution failed (unknown handle, offline) — the UI can
    /// say the default host will be tried.
    public private(set) var pdsResolutionFailed: Bool = false

    @ObservationIgnored private var resolveTask: Task<Void, Never>? = nil

    public var canSubmit: Bool {
        !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !appPassword.isEmpty
    }

    public var canSubmitTwoFactor: Bool {
        twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
    }

    /// Normalizes the handle: strips leading @ and ensures bsky.social suffix if bare.
    /// Emails pass through untouched — Bluesky accepts them as identifiers.
    public var normalizedHandle: String {
        var h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("@") { h = String(h.dropFirst()) }
        if h.contains("@") { return h }
        // If there's no dot, assume bsky.social
        if !h.contains(".") { h = "\(h).bsky.social" }
        return h
    }

    /// Whether the typed secret is an App Password (never asks for 2FA).
    public var isAppPassword: Bool {
        PDSResolver.isAppPassword(appPassword.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Host the sign-in will go through, for display.
    public var pdsDisplayHost: String {
        PDSResolver.displayHost(resolvedPDS ?? PDSResolver.defaultPDS)
    }

    /// Call whenever `handle` changes: re-resolves the hosting service
    /// after the person pauses typing.
    public func handleDidChange() {
        resolveTask?.cancel()
        resolvedPDS = nil
        pdsResolutionFailed = false
        let candidate = normalizedHandle
        guard PDSResolver.isResolvable(candidate) else {
            isResolvingPDS = false
            return
        }
        isResolvingPDS = true
        resolveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let result = try? await PDSResolver.resolve(handle: candidate)
            guard !Task.isCancelled, let self else { return }
            self.resolvedPDS = result
            self.pdsResolutionFailed = result == nil
            self.isResolvingPDS = false
        }
    }
}
