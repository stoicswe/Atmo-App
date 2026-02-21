import Foundation
import Observation

@Observable
@MainActor
final class AuthViewModel {
    var handle: String = ""
    var appPassword: String = ""
    var twoFactorCode: String = ""

    var canSubmit: Bool {
        !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !appPassword.isEmpty
    }

    var canSubmitTwoFactor: Bool {
        twoFactorCode.count == 6
    }

    /// Normalizes the handle: strips leading @ and ensures bsky.social suffix if bare.
    var normalizedHandle: String {
        var h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("@") { h = String(h.dropFirst()) }
        // If there's no dot, assume bsky.social
        if !h.contains(".") { h = "\(h).bsky.social" }
        return h
    }
}
