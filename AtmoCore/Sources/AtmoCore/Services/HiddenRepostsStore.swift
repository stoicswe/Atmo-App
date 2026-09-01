import Foundation
import Observation

// MARK: - HiddenRepostsStore
// "Hide reposts in feeds" from a profile's ··· menu: a per-account,
// device-local preference (the official app keeps it client-side too —
// there is no lexicon for it). Feeds drop any post whose feed reason is a
// repost BY one of these accounts; the account's own posts still show.
@Observable
@MainActor
public final class HiddenRepostsStore {

    public static let shared = HiddenRepostsStore()

    public private(set) var hiddenDIDs: Set<String>

    private let defaults: UserDefaults
    private let key = "atmo.feed.hiddenRepostDIDs"

    /// Internal so tests can point the store at a scratch suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hiddenDIDs = Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func isHidingReposts(from did: String) -> Bool {
        hiddenDIDs.contains(did)
    }

    public func setHidingReposts(_ hidden: Bool, from did: String) {
        if hidden {
            hiddenDIDs.insert(did)
        } else {
            hiddenDIDs.remove(did)
        }
        defaults.set(Array(hiddenDIDs).sorted(), forKey: key)
    }

    /// Drops feed entries that are reposts by a hidden account.
    public func filter(_ posts: [PostItem]) -> [PostItem] {
        guard !hiddenDIDs.isEmpty else { return posts }
        return posts.filter { !Self.isHiddenRepost(reason: $0.reason, hiddenDIDs: hiddenDIDs) }
    }

    /// Pure predicate behind `filter` — only reposts are affected.
    public nonisolated static func isHiddenRepost(reason: PostItem.FeedReason?, hiddenDIDs: Set<String>) -> Bool {
        guard case .repost(let byDID, _, _, _) = reason else { return false }
        return hiddenDIDs.contains(byDID)
    }
}
