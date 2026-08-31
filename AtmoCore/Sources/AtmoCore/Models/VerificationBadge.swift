import Foundation
import ATProtoKit

/// Bluesky account verification, distilled to what display needs.
public enum VerificationBadge: Sendable, Hashable {
    /// A verified account.
    case verified
    /// A trusted verifier — an account that can verify others.
    case trustedVerifier

    /// Distills the lexicon's verification state; nil when the account is
    /// unverified or its verification is invalid.
    init?(state: AppBskyLexicon.Actor.VerificationStateDefinition?) {
        guard let state else { return nil }
        if state.trustedVerifiedStatus == .valid {
            self = .trustedVerifier
        } else if state.verifiedStatus == .valid {
            self = .verified
        } else {
            return nil
        }
    }
}
