import Foundation
import Observation

@Observable
@MainActor
public final class AuthViewModel {
    public init() {}

    public var handle: String = ""
    public var appPassword: String = ""
    public var twoFactorCode: String = ""

    public var canSubmit: Bool {
        !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !appPassword.isEmpty
    }

    public var canSubmitTwoFactor: Bool {
        twoFactorCode.count == 6
    }

    /// Normalizes the handle: strips leading @ and ensures bsky.social suffix if bare.
    public var normalizedHandle: String {
        var h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("@") { h = String(h.dropFirst()) }
        // If there's no dot, assume bsky.social
        if !h.contains(".") { h = "\(h).bsky.social" }
        return h
    }
}
