import Foundation
import Observation

// MARK: - Account Profile Cache
/// The signed-in account's card details, kept on the device so Settings
/// shows them instantly instead of fetching on every visit. Profile
/// fields refresh quietly once a day; the join date never changes once
/// known, so it's kept for good. One snapshot per DID.
@Observable
@MainActor
public final class AccountProfileCache {

    public static let shared = AccountProfileCache()

    public struct Snapshot: Codable, Equatable, Sendable {
        public var did: String
        public var handle: String
        public var displayName: String?
        public var bio: String?
        public var avatarURL: URL?
        /// "verified" / "trustedVerifier" / nil.
        public var verification: String?
        public var memberSince: Date?
        public var fetchedAt: Date
        /// The account accepts DMs at all (chat declaration isn't "none").
        /// Nil when unknown — treated as enabled.
        public var dmsEnabled: Bool? = nil

        public init(did: String, handle: String, displayName: String?, bio: String?, avatarURL: URL?, verification: String?, memberSince: Date?, fetchedAt: Date, dmsEnabled: Bool? = nil) {
            self.did = did
            self.handle = handle
            self.displayName = displayName
            self.bio = bio
            self.avatarURL = avatarURL
            self.verification = verification
            self.memberSince = memberSince
            self.fetchedAt = fetchedAt
            self.dmsEnabled = dmsEnabled
        }

        public init(profile: ProfileModel, memberSince: Date?, fetchedAt: Date = Date()) {
            self.init(
                did: profile.did,
                handle: profile.handle,
                displayName: profile.displayName,
                bio: profile.description,
                avatarURL: profile.avatarURL,
                verification: profile.verification.map { badge in
                    switch badge {
                    case .verified: return "verified"
                    case .trustedVerifier: return "trustedVerifier"
                    }
                },
                memberSince: memberSince,
                fetchedAt: fetchedAt,
                dmsEnabled: profile.chatAllowIncoming.map { $0 != "none" }
            )
        }

        public var verificationBadge: VerificationBadge? {
            switch verification {
            case "verified": return .verified
            case "trustedVerifier": return .trustedVerifier
            default: return nil
            }
        }
    }

    /// Profile fields older than this are refreshed in the background.
    nonisolated public static let maxAge: TimeInterval = 24 * 60 * 60

    public private(set) var snapshots: [String: Snapshot] = [:]

    private let defaults: UserDefaults
    private let key = "atmo.account.profileCache"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshots = (try? decoder.decode([String: Snapshot].self, from: data)) ?? [:]
        }
    }

    public func snapshot(for did: String) -> Snapshot? {
        snapshots[did]
    }

    /// Whether the cached profile fields should be refreshed. Pure rule.
    nonisolated public static func isStale(_ snapshot: Snapshot?, now: Date) -> Bool {
        guard let snapshot else { return true }
        return now.timeIntervalSince(snapshot.fetchedAt) > maxAge
    }

    public func isStale(for did: String, now: Date = Date()) -> Bool {
        Self.isStale(snapshots[did], now: now)
    }

    /// Stores fresh profile fields; a known join date is never replaced
    /// by nil (it can't change, and a fallback lookup may have failed).
    public func store(profile: ProfileModel, memberSince: Date?) {
        let kept = memberSince ?? snapshots[profile.did]?.memberSince
        snapshots[profile.did] = Snapshot(profile: profile, memberSince: kept)
        persist()
    }

    public func clear() {
        snapshots = [:]
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshots) {
            defaults.set(data, forKey: key)
        }
    }
}
