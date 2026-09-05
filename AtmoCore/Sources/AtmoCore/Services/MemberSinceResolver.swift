import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ATProtoKit

// MARK: - Member Since
/// When an account joined Bluesky, best source first:
///   1. the profile's own `createdAt`;
///   2. the DID's first PLC directory operation (the identity's birth —
///      `plc.directory/<did>/log/audit`), for did:plc accounts;
///   3. the earliest post found in the account's recent history.
public enum MemberSinceResolver {

    public static func resolve(profile: ProfileModel, kit: ATProtoKit?, session: URLSession = .shared) async -> Date? {
        if let created = profile.createdAt { return created }
        if let plc = await plcCreation(did: profile.did, session: session) { return plc }
        return await earliestPost(did: profile.did, kit: kit)
    }

    static func plcCreation(did: String, session: URLSession) async -> Date? {
        guard did.hasPrefix("did:plc:"),
              let url = URL(string: "https://plc.directory/\(did)/log/audit"),
              let (data, _) = try? await session.data(from: url)
        else { return nil }
        return earliestPLCOperation(in: data)
    }

    /// The earliest `createdAt` in a PLC audit log payload. Pure; unit-tested.
    public static func earliestPLCOperation(in data: Data) -> Date? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return entries
            .compactMap { $0["createdAt"] as? String }
            .compactMap { formatter.date(from: $0) ?? plain.date(from: $0) }
            .min()
    }

    /// Walks a few pages of the author's feed for the oldest post.
    static func earliestPost(did: String, kit: ATProtoKit?, maxPages: Int = 5) async -> Date? {
        guard let kit else { return nil }
        var cursor: String? = nil
        var earliest: Date? = nil
        for _ in 0..<maxPages {
            guard let output = try? await kit.getAuthorFeed(by: did, limit: 100, cursor: cursor) else { break }
            for item in output.feed {
                let created = PostItem(feedPost: item).createdAt
                earliest = earliest.map { min($0, created) } ?? created
            }
            guard let next = output.cursor, !output.feed.isEmpty else { break }
            cursor = next
        }
        return earliest
    }
}
