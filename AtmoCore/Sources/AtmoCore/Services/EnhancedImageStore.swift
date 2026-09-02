import Foundation
import Observation

// MARK: - Enhanced Image Store
/// Keeps upscaled ("Enhanced") copies of images, in three tiers:
///   • transient — Caches; kept while there's room, the system may purge.
///   • bookmarked — Application Support; kept for as long as the post that
///     owns the image stays bookmarked.
///   • vault — Application Support, separate directory, complete file
///     protection on iOS; kept while the post is in the Vault, deleted the
///     moment it leaves, and never served while the Vault is locked.
///
/// The bookmark and Vault stores call `reconcileFromStores()` after every
/// change, so files follow a post as it moves between tiers. Nothing here
/// is ever donated to a search index, and none of it syncs.
@Observable
@MainActor
public final class EnhancedImageStore {

    public static let shared = EnhancedImageStore()

    public enum Tier: String, CaseIterable, Sendable {
        case transient, bookmarked, vault
    }

    private let persistentRoot: URL
    private let transientRoot: URL
    /// Image URL → owning post URI ("" when the image was enhanced with no
    /// post context).
    private var index: [String: String] = [:]
    /// Bumped whenever files change, so views re-check what's cached.
    public private(set) var generation = 0

    private static let transientLimit = 60

    /// Internal so tests can point the store at scratch directories.
    init(persistentRoot: URL, transientRoot: URL) {
        self.persistentRoot = persistentRoot
        self.transientRoot = transientRoot
        loadIndex()
    }

    private convenience init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.init(
            persistentRoot: support.appendingPathComponent("EnhancedImages", isDirectory: true),
            transientRoot: caches.appendingPathComponent("EnhancedImages", isDirectory: true)
        )
    }

    // MARK: Lookup

    /// Where the enhanced copy of `imageURL` lives, if anywhere. Vault-tier
    /// files are withheld while the Vault is locked.
    public func fileURL(for imageURL: URL, vaultUnlocked: Bool) -> URL? {
        for tier in Tier.allCases {
            let candidate = location(for: imageURL, tier: tier)
            if FileManager.default.fileExists(atPath: candidate.path) {
                if tier == .vault, !vaultUnlocked { return nil }
                return candidate
            }
        }
        return nil
    }

    public func fileURL(for imageURL: URL) -> URL? {
        fileURL(for: imageURL, vaultUnlocked: VaultLock.shared.isUnlocked)
    }

    public func tier(for imageURL: URL) -> Tier? {
        Tier.allCases.first { FileManager.default.fileExists(atPath: location(for: imageURL, tier: $0).path) }
    }

    // MARK: Store

    /// Saves an enhanced copy into the tier the owning post currently
    /// calls for.
    public func store(_ data: Data, for imageURL: URL, postURI: String?, bookmarked: Set<String>, vaulted: Set<String>) {
        let tier = Self.desiredTier(postURI: postURI, bookmarked: bookmarked, vaulted: vaulted)
        // One copy only: drop any other tier's file first.
        for other in Tier.allCases where other != tier {
            try? FileManager.default.removeItem(at: location(for: imageURL, tier: other))
        }
        write(data, to: location(for: imageURL, tier: tier), protected: tier == .vault)
        index[imageURL.absoluteString] = postURI ?? ""
        saveIndex()
        pruneTransient()
        generation += 1
    }

    public func store(_ data: Data, for imageURL: URL, postURI: String?) {
        store(
            data, for: imageURL, postURI: postURI,
            bookmarked: Set(BookmarkStore.shared.bookmarks.map(\.uri)),
            vaulted: Set(VaultStore.shared.state.posts.map(\.uri))
        )
    }

    // MARK: Reconcile

    /// Moves every enhanced file into the tier its post now calls for:
    /// bookmarked ↔ vault follow the post; a post that left both sends a
    /// bookmarked copy back to the transient cache and deletes a Vault
    /// copy outright (nothing private lingers in Caches).
    public func reconcile(bookmarked: Set<String>, vaulted: Set<String>) {
        var changed = false
        for (key, postURI) in index {
            guard let imageURL = URL(string: key), let current = tier(for: imageURL) else { continue }
            let desired = Self.desiredTier(postURI: postURI.isEmpty ? nil : postURI, bookmarked: bookmarked, vaulted: vaulted)
            guard desired != current else { continue }
            let from = location(for: imageURL, tier: current)
            if current == .vault, desired == .transient {
                try? FileManager.default.removeItem(at: from)
                index[key] = nil
            } else {
                move(from: from, to: location(for: imageURL, tier: desired), protected: desired == .vault)
            }
            changed = true
        }
        if changed {
            saveIndex()
            generation += 1
        }
    }

    public func reconcileFromStores() {
        guard !index.isEmpty else { return }
        reconcile(
            bookmarked: Set(BookmarkStore.shared.bookmarks.map(\.uri)),
            vaulted: Set(VaultStore.shared.state.posts.map(\.uri))
        )
    }

    /// Which tier an image belongs in, given its post's membership.
    /// Vault wins over bookmarks (a post can't be in both, but if it were,
    /// the private tier is the safe one). Pure; unit-tested.
    nonisolated public static func desiredTier(postURI: String?, bookmarked: Set<String>, vaulted: Set<String>) -> Tier {
        guard let postURI, !postURI.isEmpty else { return .transient }
        if vaulted.contains(postURI) { return .vault }
        if bookmarked.contains(postURI) { return .bookmarked }
        return .transient
    }

    // MARK: Maintenance

    /// Bytes on disk across every tier.
    public func totalBytes() -> Int64 {
        var total: Int64 = 0
        for directory in [transientRoot] + Tier.allCases.filter { $0 != .transient }.map({ persistentRoot.appendingPathComponent($0.rawValue, isDirectory: true) }) {
            total += Self.directoryBytes(directory)
        }
        return total
    }

    /// Removes every enhanced copy, in every tier, and the index. The
    /// bookmarks and Vault entries themselves are untouched — an image can
    /// simply be enhanced again.
    public func clearAll() {
        let fm = FileManager.default
        try? fm.removeItem(at: transientRoot)
        for tier in Tier.allCases where tier != .transient {
            try? fm.removeItem(at: persistentRoot.appendingPathComponent(tier.rawValue, isDirectory: true))
        }
        index = [:]
        try? fm.removeItem(at: indexURL)
        generation += 1
    }

    nonisolated public static func directoryBytes(_ directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    // MARK: Files

    func location(for imageURL: URL, tier: Tier) -> URL {
        let root = tier == .transient ? transientRoot : persistentRoot.appendingPathComponent(tier.rawValue, isDirectory: true)
        return root.appendingPathComponent(Self.fileName(for: imageURL))
    }

    /// Stable, filesystem-safe name: FNV-1a 64-bit of the URL. Pure.
    nonisolated public static func fileName(for imageURL: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in imageURL.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16) + ".jpg"
    }

    private func write(_ data: Data, to url: URL, protected: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        applyProtection(to: url, protected: protected)
        excludeFromBackup(url.deletingLastPathComponent())
    }

    private func move(from: URL, to: URL, protected: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: to)
        try? fm.moveItem(at: from, to: to)
        applyProtection(to: to, protected: protected)
        excludeFromBackup(to.deletingLastPathComponent())
    }

    private func applyProtection(to url: URL, protected: Bool) {
#if os(iOS)
        let level: FileProtectionType = protected ? .complete : .completeUntilFirstUserAuthentication
        try? FileManager.default.setAttributes([.protectionKey: level], ofItemAtPath: url.path)
#endif
    }

    /// Enhanced copies are re-creatable; keep them out of iCloud backups.
    private func excludeFromBackup(_ directory: URL) {
#if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
#endif
    }

    /// Oldest-first trim of the transient tier.
    private func pruneTransient() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: transientRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ), files.count > Self.transientLimit else { return }
        let dated = files.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url, date)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(files.count - Self.transientLimit) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Index

    private var indexURL: URL { persistentRoot.appendingPathComponent("index.json") }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        index = decoded
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: persistentRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
