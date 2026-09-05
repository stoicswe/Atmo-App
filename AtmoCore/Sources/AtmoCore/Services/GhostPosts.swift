import Foundation
import Observation

// MARK: - Ghost Post Policy
/// A Ghost Post is an ordinary Bluesky post wearing a self-label marker,
/// published with replies and quotes closed, that the author's own app
/// deletes 24 hours after it was created. Bluesky has no server-side
/// ephemerality: the gates are enforced by the network, the marker lets
/// Atmo render the ghost treatment, and the deletion is the app's job —
/// which is why the feature is opt-in behind a warning.
public enum GhostPostPolicy {
    public static let enabledKey = "atmo.ghost.enabled"
    /// Self-label value that marks a post as a ghost. Other clients don't
    /// know it and ignore it.
    public static let label = "atmo-ghost"
    /// How long a ghost stays up before the app takes it down.
    public static let lifetime: TimeInterval = 24 * 60 * 60

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    public static func isGhost(labels: [String]) -> Bool {
        labels.contains(label)
    }

    public static func isGhost(_ post: PostItem) -> Bool {
        isGhost(labels: post.contentLabels)
    }

    public static func expiresAt(createdAt: Date) -> Date {
        createdAt.addingTimeInterval(lifetime)
    }

    public static func expiresAt(_ post: PostItem) -> Date {
        expiresAt(createdAt: post.createdAt)
    }

    /// "23h left", "40m left", "ending soon" — for the badge.
    public static func remainingText(until expiry: Date, now: Date = Date()) -> String {
        let seconds = expiry.timeIntervalSince(now)
        if seconds <= 60 { return "ending soon" }
        if seconds < 3600 { return "\(Int(seconds / 60))m left" }
        return "\(Int((seconds / 3600).rounded(.down)))h left"
    }
}

// MARK: - Ghost Post Entry
public struct GhostPostEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String { uri }
    public let uri: String
    public let text: String
    public let createdAt: Date
    public let expiresAt: Date
    /// Set once the record has been deleted (archive entries).
    public var endedAt: Date? = nil

    public init(uri: String, text: String, createdAt: Date, expiresAt: Date, endedAt: Date? = nil) {
        self.uri = uri
        self.text = text
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.endedAt = endedAt
    }
}

// MARK: - Ghost Post Store
/// The author's own ghost posts: the ones still up (with their deadlines)
/// and the archive of ones already taken down. Dual-written to the synced
/// key-value store so any of the person's devices can do the cleanup.
@Observable
@MainActor
public final class GhostPostStore {

    public static let shared = GhostPostStore()

    public private(set) var active: [GhostPostEntry] = []
    public private(set) var archive: [GhostPostEntry] = []
    public private(set) var isCleaningUp = false

    private let defaults: UserDefaults
    private let syncedStore: any SyncedKeyValueStore
    private let activeKey = "atmo.ghost.active"
    private let archiveKey = "atmo.ghost.archive"
    private static let archiveLimit = 100
    @ObservationIgnored private weak var service: ATProtoService?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol? = nil
    @ObservationIgnored private var externalChangeTask: Task<Void, Never>? = nil

    init(defaults: UserDefaults = .standard, syncedStore: any SyncedKeyValueStore = Atmo.platform.syncedKeyValue) {
        self.defaults = defaults
        self.syncedStore = syncedStore
        load()
        observeRemoteChanges()
    }

    // MARK: Recording

    /// Called right after a ghost post is published.
    public func record(uri: String, text: String, createdAt: Date = Date()) {
        let entry = GhostPostEntry(
            uri: uri, text: text, createdAt: createdAt,
            expiresAt: GhostPostPolicy.expiresAt(createdAt: createdAt)
        )
        active.removeAll { $0.uri == uri }
        active.insert(entry, at: 0)
        persist()
    }

    public func isGhost(uri: String) -> Bool {
        active.contains { $0.uri == uri }
    }

    // MARK: Cleanup

    /// Entries past their deadline. Pure; unit-tested.
    nonisolated public static func due(in entries: [GhostPostEntry], now: Date) -> [GhostPostEntry] {
        entries.filter { $0.expiresAt <= now }
    }

    /// Wires the live service and runs a pass now; another runs whenever
    /// the app returns to the foreground.
    public func attach(service: ATProtoService) {
        self.service = service
        Task { await cleanup(service: service) }
        guard foregroundObserver == nil, let name = Atmo.platform.foregroundNotification else { return }
        // Closure observer rather than the async sequence: Linux Foundation
        // has no `notifications(named:)`.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let service = self.service else { return }
                await self.cleanup(service: service)
            }
        }
    }

    /// Deletes every ghost post whose time is up and moves it to the
    /// archive. Safe to call often; no-op while nothing is due.
    public func cleanup(service: ATProtoService, now: Date = Date()) async {
        let due = Self.due(in: active, now: now)
        guard !due.isEmpty, !isCleaningUp else { return }
        await end(due, service: service, endedAt: now)
    }

    /// Takes a ghost post down before its time.
    public func endNow(uri: String, service: ATProtoService) async {
        guard let entry = active.first(where: { $0.uri == uri }) else { return }
        await end([entry], service: service, endedAt: Date())
    }

    private func end(_ entries: [GhostPostEntry], service: ATProtoService, endedAt: Date) async {
        guard let bluesky = service.atProtoBluesky else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }
        for entry in entries {
            do {
                try await bluesky.deleteRecord(.recordURI(atURI: entry.uri))
            } catch {
                // Already gone counts as done; anything else retries next pass.
                if !Self.isAlreadyGone(error) { continue }
            }
            active.removeAll { $0.uri == entry.uri }
            var archived = entry
            archived.endedAt = endedAt
            archive.insert(archived, at: 0)
        }
        if archive.count > Self.archiveLimit {
            archive = Array(archive.prefix(Self.archiveLimit))
        }
        persist()
    }

    nonisolated static func isAlreadyGone(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("not found") || text.contains("could not find") || text.contains("404")
    }

    public func removeFromArchive(uri: String) {
        archive.removeAll { $0.uri == uri }
        persist()
    }

    public func clearArchive() {
        archive = []
        persist()
    }

    // MARK: Persistence (dual write, union merge on load)

    private func load() {
        let localActive = decode(defaults.data(forKey: activeKey))
        let syncedActive = decode(syncedStore.data(forKey: activeKey))
        active = Self.merged(localActive, syncedActive)
        let localArchive = decode(defaults.data(forKey: archiveKey))
        let syncedArchive = decode(syncedStore.data(forKey: archiveKey))
        archive = Array(Self.merged(localArchive, syncedArchive).prefix(Self.archiveLimit))
    }

    /// Union by URI, newest first. A post another device already ended
    /// (in its archive) must not linger as active here — the caller
    /// resolves that by checking the archive when a pass runs.
    nonisolated static func merged(_ a: [GhostPostEntry], _ b: [GhostPostEntry]) -> [GhostPostEntry] {
        var seen = Set<String>()
        return (a + b)
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seen.insert($0.uri).inserted }
    }

    private func persist() {
        // An entry in the archive is never also active.
        let archivedURIs = Set(archive.map(\.uri))
        active.removeAll { archivedURIs.contains($0.uri) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(active) {
            defaults.set(data, forKey: activeKey)
            syncedStore.set(data, forKey: activeKey)
        }
        if let data = try? encoder.encode(archive) {
            defaults.set(data, forKey: archiveKey)
            syncedStore.set(data, forKey: archiveKey)
        }
        syncedStore.synchronize()
    }

    private func decode(_ data: Data?) -> [GhostPostEntry] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([GhostPostEntry].self, from: data)) ?? []
    }

    private func observeRemoteChanges() {
        let keys = Set([activeKey, archiveKey])
        let changes = syncedStore.externalChanges()
        externalChangeTask = Task { [weak self] in
            for await changed in changes where !keys.isDisjoint(with: changed) {
                Task { @MainActor [weak self] in
                    self?.load()
                    if let self, let service = self.service {
                        await self.cleanup(service: service)
                    }
                }
            }
        }
    }
}
