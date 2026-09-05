import Foundation
import Observation
import ATProtoKit

// MARK: - Liked Posts Store
/// The user's like history, recorded as each like lands. The history
/// collects liked *posts* only — likes on replies stay out (see
/// `shouldRecord`). Past likes trickle in through `continueBackfill`,
/// which walks the account's own `app.bsky.feed.like` records.
///
/// Persistence: a local JSON file (always available) mirrored to the
/// platform's synced file store — on Apple platforms the app's iCloud
/// ubiquity container, OUTSIDE Documents/, so the history syncs across
/// devices without ever appearing in iCloud Drive. Unlike the old KVS
/// backing there is no 1 MB budget, so no tight entry cap.
///
/// Concurrent writes from two devices surface as file *versions*; the
/// merge is domain-aware rather than textual — the payload is a set
/// keyed by post URI, so union with newest-likedAt-wins plus timestamped
/// removal tombstones resolves every conflict deterministically.
@Observable
@MainActor
public final class LikedPostsStore {

    public static let shared = LikedPostsStore()

    /// Safety ceiling only (memory/UI bound) — the user's retention
    /// window (Settings → Appearance → Liked History) is the real trim.
    public static let maxEntries = 20_000
    /// Removal tombstones kept for cross-device propagation.
    static let maxTombstones = 2_000

    // MARK: State

    public private(set) var likedPosts: [LikedPost] = []

    /// URI → when the user removed it from the history (or unliked).
    /// Synced so removals propagate; a re-like AFTER the removal wins.
    @ObservationIgnored private var removedTombstones: [String: Date] = [:]

    /// A backfill pass is currently fetching pages (drives the
    /// "Syncing past likes…" footer).
    public private(set) var isBackfilling = false

    /// The full like history has been walked (or nothing newer than the
    /// retention window remains to fetch).
    public private(set) var backfillComplete: Bool

    // MARK: Private

    private let syncedFiles = Atmo.platform.syncedFiles
    private static let cloudFileName = "liked-posts.json"
    /// KVS-era storage, migrated (and cleared) on first launch.
    private static let legacyStoreKey = "com.atmo.app.likedPosts"
    private static let backfillCursorKey = "com.atmo.app.likedPosts.backfillCursor"
    private static let backfillCompleteKey = "com.atmo.app.likedPosts.backfillComplete"
    private var cloudSyncTask: Task<Void, Never>? = nil

    private init() {
        backfillComplete = UserDefaults.standard.bool(forKey: Self.backfillCompleteKey)
        loadLocal()
        startCloudSync()
    }

    // MARK: - Payload
    // The synced file's shape. `removed` carries removal tombstones with
    // their timestamps so "removed here" vs "re-liked there" resolves by
    // time, not by which device wrote last.
    struct Payload: Codable {
        var posts: [LikedPost]
        var removed: [String: Date]?
    }

    /// Domain-aware merge of any number of payload versions (local state
    /// plus every cloud version, conflicts included). Pure, unit-tested:
    ///   • posts union by URI, newest likedAt wins
    ///   • removal tombstones union by URI, newest removedAt wins
    ///   • a tombstone deletes any like at-or-before it; a later re-like
    ///     survives and retires the tombstone
    ///   • retention + caps applied last
    static func mergedPayload(
        _ payloads: [Payload],
        retention: LikedPostsRetention,
        now: Date = Date()
    ) -> Payload {
        var newestByURI: [String: LikedPost] = [:]
        var removed: [String: Date] = [:]
        for payload in payloads {
            for post in payload.posts {
                if let existing = newestByURI[post.uri], existing.likedAt >= post.likedAt { continue }
                newestByURI[post.uri] = post
            }
            for (uri, removedAt) in payload.removed ?? [:] {
                if let existing = removed[uri], existing >= removedAt { continue }
                removed[uri] = removedAt
            }
        }

        let survivors = newestByURI.values.filter { post in
            guard let removedAt = removed[post.uri] else { return true }
            return post.likedAt > removedAt
        }
        // Tombstones beaten by a re-like retire; the rest keep newest.
        let standing = removed.filter { uri, removedAt in
            newestByURI[uri].map { $0.likedAt <= removedAt } ?? true
        }
        let cappedTombstones = Dictionary(
            uniqueKeysWithValues: standing
                .sorted { $0.value > $1.value }
                .prefix(maxTombstones)
                .map { ($0.key, $0.value) }
        )
        return Payload(
            posts: pruned(Array(survivors), retention: retention, now: now),
            removed: cappedTombstones
        )
    }

    // MARK: - Recording

    /// The Liked history keeps liked POSTS — likes on replies stay out.
    /// Pure, so the rule is unit-testable and shared by live recording
    /// and the backfill.
    public static func shouldRecord(_ post: PostItem) -> Bool {
        post.replyParentURI == nil
    }

    /// Called after a like succeeds on the server.
    public func recordLike(_ post: PostItem) {
        guard Self.shouldRecord(post) else { return }
        removedTombstones.removeValue(forKey: post.uri)
        likedPosts.removeAll { $0.uri == post.uri }
        likedPosts.insert(LikedPost(post: post), at: 0)
        likedPosts = Self.pruned(likedPosts, retention: .current)
        persist()
    }

    /// Called after an unlike succeeds on the server. Tombstoned so the
    /// removal reaches the user's other devices too.
    public func recordUnlike(uri: String) {
        likedPosts.removeAll { $0.uri == uri }
        removedTombstones[uri] = Date()
        trimTombstones()
        persist()
    }

    /// Removes an entry from the history (view housekeeping — does not
    /// touch the like on the server).
    public func remove(uri: String) {
        recordUnlike(uri: uri)
    }

    /// Newest-first, capped. Pure so the trim rule is unit-testable.
    public static func capped(_ posts: [LikedPost]) -> [LikedPost] {
        let sorted = posts.sorted { $0.likedAt > $1.likedAt }
        return Array(sorted.prefix(maxEntries))
    }

    /// Retention filter + cap. Pure so the expiry rule is unit-testable.
    public static func pruned(
        _ posts: [LikedPost],
        retention: LikedPostsRetention,
        now: Date = Date()
    ) -> [LikedPost] {
        guard let maxAge = retention.maxAge else { return capped(posts) }
        let cutoff = now.addingTimeInterval(-maxAge)
        return capped(posts.filter { $0.likedAt >= cutoff })
    }

    private func trimTombstones() {
        guard removedTombstones.count > Self.maxTombstones else { return }
        removedTombstones = Dictionary(
            uniqueKeysWithValues: removedTombstones
                .sorted { $0.value > $1.value }
                .prefix(Self.maxTombstones)
                .map { ($0.key, $0.value) }
        )
    }

    // MARK: - Retention

    /// The retention value last applied — lets the store detect a settings
    /// change on its own. (No UI hook: an .onChange on the Settings picker
    /// looped macOS's update-constraints pass at launch and crashed.)
    private static let lastRetentionKey = "com.atmo.app.likedPosts.lastRetention"

    /// Drops entries older than the user's retention window. Persists
    /// only when something expired, so callers can invoke it freely —
    /// the store runs it on load and on every backfill pass, so a changed
    /// setting takes effect on the next launch or Liked-view visit.
    ///
    /// A LENGTHENED window (or Forever) also restarts the backfill walk
    /// from the newest like: previously-expired history is welcome again,
    /// and the dedup pass keeps the re-walk cheap.
    public func applyRetention() {
        let current = LikedPostsRetention.current

        if let lastRaw = UserDefaults.standard.string(forKey: Self.lastRetentionKey),
           let last = LikedPostsRetention(rawValue: lastRaw),
           last != current {
            let lastAge = last.maxAge ?? .infinity
            let currentAge = current.maxAge ?? .infinity
            if currentAge > lastAge {
                backfillComplete = false
                UserDefaults.standard.removeObject(forKey: Self.backfillCompleteKey)
                UserDefaults.standard.removeObject(forKey: Self.backfillCursorKey)
            }
        }
        UserDefaults.standard.set(current.rawValue, forKey: Self.lastRetentionKey)

        let pruned = Self.pruned(likedPosts, retention: current)
        if pruned.count != likedPosts.count {
            likedPosts = pruned
            persist()
        }
    }

    // MARK: - Backfill
    // Walks the account's own like records (com.atproto.repo.listRecords,
    // collection app.bsky.feed.like) newest→oldest, hydrating each page
    // via app.bsky.feed.getPosts. The like record carries the exact
    // likedAt; hydration supplies author/text and the reply check.
    //
    // Deliberately incremental: a few pages per call, cursor persisted
    // between runs, so history syncs in over successive visits without
    // hammering rate limits.

    /// Pages fetched per call — ~250 likes a visit.
    private static let backfillPageBudget = 5

    public func continueBackfill(service: ATProtoService) async {
        // Entries age out even when nothing else changes — every pass
        // starts with a retention sweep, whether or not backfill runs.
        applyRetention()

        guard !isBackfilling, !backfillComplete,
              likedPosts.count < Self.maxEntries,
              let kit = service.atProtoKit,
              let did = service.currentUserDID
        else { return }

        isBackfilling = true
        defer { isBackfilling = false }

        let retention = LikedPostsRetention.current
        let retentionCutoff = retention.maxAge.map { Date().addingTimeInterval(-$0) }
        var cursor = UserDefaults.standard.string(forKey: Self.backfillCursorKey)
        var pagesFetched = 0

        while pagesFetched < Self.backfillPageBudget, likedPosts.count < Self.maxEntries {
            do {
                let page = try await kit.listRecords(
                    from: did,
                    collection: "app.bsky.feed.like",
                    limit: 50,
                    cursor: cursor
                )
                pagesFetched += 1

                // Like subject URI → the like's own timestamp, skipping
                // entries the history already has (their likedAt stands),
                // likes past the retention window, and likes the user has
                // removed from the history (unless re-liked afterwards).
                var likedAtByURI: [String: Date] = [:]
                var orderedURIs: [String] = []
                var sawLikeInsideWindow = false
                var sawAnyLike = false
                for record in page.records {
                    guard let like = record.value?.getRecord(ofType: AppBskyLexicon.Feed.LikeRecord.self) else {
                        continue
                    }
                    sawAnyLike = true
                    if let retentionCutoff, like.createdAt < retentionCutoff {
                        continue
                    }
                    sawLikeInsideWindow = true
                    let subjectURI = like.subject.recordURI
                    if let removedAt = removedTombstones[subjectURI], like.createdAt <= removedAt {
                        continue
                    }
                    guard likedAtByURI[subjectURI] == nil,
                          !likedPosts.contains(where: { $0.uri == subjectURI })
                    else { continue }
                    likedAtByURI[subjectURI] = like.createdAt
                    orderedURIs.append(subjectURI)
                }

                // Records walk newest→oldest: a page whose likes all sit
                // past the retention cutoff means everything further back
                // is expired too — the walk is done.
                if sawAnyLike, !sawLikeInsideWindow, retentionCutoff != nil {
                    finishBackfill()
                    return
                }

                // Hydrate in getPosts' 25-URI batches. Deleted or blocked
                // subjects simply don't come back — they drop out here.
                var fetched: [LikedPost] = []
                var start = 0
                while start < orderedURIs.count {
                    let batch = Array(orderedURIs[start..<min(start + 25, orderedURIs.count)])
                    start += 25
                    let hydrated = try await kit.getPosts(batch)
                    for postView in hydrated.posts {
                        let post = PostItem(postView: postView)
                        // Liked POSTS only — replies stay out of the history.
                        guard Self.shouldRecord(post) else { continue }
                        fetched.append(LikedPost(post: post, likedAt: likedAtByURI[post.uri] ?? post.indexedAt))
                    }
                }

                if !fetched.isEmpty {
                    likedPosts = Self.pruned(likedPosts + fetched, retention: retention)
                    persist()
                }

                cursor = page.cursor
                if let cursor {
                    UserDefaults.standard.set(cursor, forKey: Self.backfillCursorKey)
                } else {
                    // The whole history has been walked.
                    finishBackfill()
                    return
                }
            } catch {
                // Transient failure — resume from the saved cursor next time.
                return
            }
        }

        if likedPosts.count >= Self.maxEntries {
            finishBackfill()
        }
    }

    private func finishBackfill() {
        backfillComplete = true
        UserDefaults.standard.set(true, forKey: Self.backfillCompleteKey)
        UserDefaults.standard.removeObject(forKey: Self.backfillCursorKey)
    }

    // MARK: - Persistence (local file baseline + synced cloud file)

    /// Application Support baseline — always available, no size budget.
    private static var localFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Atmo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("liked-posts.json")
    }

    private func loadLocal() {
        if let data = try? Data(contentsOf: Self.localFileURL),
           let payload = Self.decodePayload(data) {
            apply(Self.mergedPayload([payload], retention: .current))
            return
        }
        migrateLegacyStorage()
    }

    /// One-shot migration from the KVS-era storage (UserDefaults blob +
    /// the 1 MB-budget iCloud KVS key, which is cleared to hand its
    /// budget back to bookmarks and folders).
    private func migrateLegacyStorage() {
        var legacy: [LikedPost] = []
        if let data = UserDefaults.standard.data(forKey: Self.legacyStoreKey),
           let posts = Self.decodeLegacy(data) {
            legacy += posts
        }
        let kvs = Atmo.platform.syncedKeyValue
        if let data = kvs.data(forKey: Self.legacyStoreKey),
           let posts = Self.decodeLegacy(data) {
            legacy += posts
        }
        guard !legacy.isEmpty else { return }
        apply(Self.mergedPayload([Payload(posts: legacy, removed: [:])], retention: .current))
        persist()
        UserDefaults.standard.removeObject(forKey: Self.legacyStoreKey)
        kvs.removeValue(forKey: Self.legacyStoreKey)
        kvs.synchronize()
    }

    private func apply(_ payload: Payload) {
        likedPosts = payload.posts
        removedTombstones = payload.removed ?? [:]
    }

    private func persist() {
        let payload = Payload(posts: likedPosts, removed: removedTombstones)
        guard let data = Self.encodePayload(payload) else { return }
        try? data.write(to: Self.localFileURL, options: .atomic)
        let files = syncedFiles
        Task.detached {
            await files.write(data, name: Self.cloudFileName)
        }
    }

    // MARK: - Cloud sync

    private func startCloudSync() {
        let files = syncedFiles
        cloudSyncTask = Task { [weak self] in
            await self?.mergeFromCloud()
            for await _ in files.externalChanges(name: Self.cloudFileName) {
                await self?.mergeFromCloud()
            }
        }
    }

    /// Pulls every cloud version (current + conflicts), merges with local
    /// state, and writes the resolution back when anything differed —
    /// which is also what marks the conflict versions resolved.
    private func mergeFromCloud() async {
        let versions = await syncedFiles.readVersions(name: Self.cloudFileName)
        guard !versions.isEmpty else { return }
        var payloads = versions.compactMap(Self.decodePayload)
        payloads.append(Payload(posts: likedPosts, removed: removedTombstones))
        let merged = Self.mergedPayload(payloads, retention: .current)
        let changed = merged.posts != likedPosts || (merged.removed ?? [:]) != removedTombstones
        apply(merged)
        if changed || versions.count > 1 {
            persist()
        }
    }

    // MARK: - Codec

    static func encodePayload(_ payload: Payload) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(payload)
    }

    static func decodePayload(_ data: Data) -> Payload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }

    private static func decodeLegacy(_ data: Data) -> [LikedPost]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([LikedPost].self, from: data)
    }
}
