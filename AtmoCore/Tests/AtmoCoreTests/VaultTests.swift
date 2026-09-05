import Foundation
import Testing
@testable import AtmoCore

/// The Vault's pure value core: nested folders, filing, cascade delete,
/// cycle refusal, and the unlock expiry rule.
struct VaultTests {

    @MainActor
    private func post(_ uri: String) -> BookmarkedPost {
        BookmarkedPost(post: PostItem(testURI: uri))
    }

    @Test @MainActor func addFileRemove() {
        var state = VaultState()
        let folder = state.createFolder(named: " Recipes ")!
        #expect(folder.name == "Recipes")
        state.add(post("at://a"), in: folder.id)
        state.add(post("at://b"))
        #expect(state.contains(uri: "at://a"))
        #expect(state.posts(in: folder.id).map(\.uri) == ["at://a"])
        #expect(state.posts(in: nil).map(\.uri) == ["at://b"])

        // Re-adding only re-files.
        state.add(post("at://a"), in: nil)
        #expect(state.posts.count == 2)
        #expect(state.folderID(forPostURI: "at://a") == nil)

        #expect(state.remove(uri: "at://a")?.uri == "at://a")
        #expect(!state.contains(uri: "at://a"))
        #expect(state.remove(uri: "at://missing") == nil)
    }

    @Test @MainActor func nestedFoldersPathsAndCounts() {
        var state = VaultState()
        let top = state.createFolder(named: "Work")!
        let mid = state.createFolder(named: "2026", in: top.id)!
        let leaf = state.createFolder(named: "Q3", in: mid.id)!
        #expect(state.createFolder(named: "Orphan", in: UUID()) == nil)

        state.add(post("at://1"), in: leaf.id)
        state.add(post("at://2"), in: mid.id)
        state.add(post("at://3"), in: nil)

        #expect(state.children(of: nil).map(\.id) == [top.id])
        #expect(state.children(of: top.id).map(\.id) == [mid.id])
        #expect(state.path(to: leaf.id).map(\.name) == ["Work", "2026", "Q3"])
        #expect(state.path(to: nil).isEmpty)
        #expect(state.count(in: top.id) == 2)
        #expect(state.count(in: leaf.id) == 1)
        #expect(state.flattened().map { $0.depth } == [0, 1, 2])
        #expect(state.isSameOrDescendant(leaf.id, of: top.id))
        #expect(!state.isSameOrDescendant(top.id, of: leaf.id))
    }

    @Test @MainActor func deleteCascadesAndLiftsPostsToParent() {
        var state = VaultState()
        let top = state.createFolder(named: "Work")!
        let mid = state.createFolder(named: "2026", in: top.id)!
        let leaf = state.createFolder(named: "Q3", in: mid.id)!
        state.add(post("at://1"), in: leaf.id)
        state.add(post("at://2"), in: mid.id)

        state.deleteFolder(id: mid.id)
        #expect(state.folder(id: mid.id) == nil)
        #expect(state.folder(id: leaf.id) == nil)
        #expect(state.folder(id: top.id) != nil)
        #expect(state.folderID(forPostURI: "at://1") == top.id)
        #expect(state.folderID(forPostURI: "at://2") == top.id)
        #expect(state.posts.count == 2)
    }

    @Test func moveFolderRefusesCycles() {
        var state = VaultState()
        let a = state.createFolder(named: "A")!
        let b = state.createFolder(named: "B", in: a.id)!
        state.moveFolder(id: a.id, to: b.id)          // would loop
        #expect(state.folder(id: a.id)?.parentID == nil)
        state.moveFolder(id: b.id, to: nil)
        #expect(state.folder(id: b.id)?.parentID == nil)
        state.moveFolder(id: b.id, to: a.id)
        #expect(state.folder(id: b.id)?.parentID == a.id)
    }

    @Test func renameAndStaleFolderMove() {
        var state = VaultState()
        let a = state.createFolder(named: "A")!
        state.renameFolder(id: a.id, to: "  ")
        #expect(state.folder(id: a.id)?.name == "A")
        state.renameFolder(id: a.id, to: " Archive ")
        #expect(state.folder(id: a.id)?.name == "Archive")
        state.move(postURI: "at://x", to: UUID())
        #expect(state.folderID(forPostURI: "at://x") == nil)
    }

    @Test func unlockExpiryRule() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!VaultLock.isUnlocked(until: nil, now: now))
        #expect(VaultLock.isUnlocked(until: now.addingTimeInterval(1), now: now))
        #expect(!VaultLock.isUnlocked(until: now.addingTimeInterval(-1), now: now))
        #expect(VaultLock.expiry(for: .fiveMinutes, from: now) == now.addingTimeInterval(300))
        #expect(VaultLock.expiry(for: .oneHour, from: now) == now.addingTimeInterval(3600))
        // "Every time" stays open for the visit; leaving the screen locks it.
        #expect(VaultLock.expiry(for: .everyTime, from: now) > now)
        #expect(VaultUnlockDuration.stored(rawValue: nil) == .fiveMinutes)
        #expect(VaultUnlockDuration.stored(rawValue: "bogus") == .fiveMinutes)
        #expect(VaultUnlockDuration.stored(rawValue: "oneHour") == .oneHour)
    }

    @Test @MainActor func leavingTheAppNoticesOnlyWhenOpen() {
        let lock = VaultLock(defaults: UserDefaults(suiteName: "atmo-vault-lock-\(UUID().uuidString)")!)
        // Locked already: leaving says nothing.
        lock.lockForLeavingApp()
        #expect(lock.autoLockNotice == nil)
        #expect(VaultLock.AutoLockReason.timerExpired.message.contains("ran out"))
        #expect(VaultLock.AutoLockReason.leftApp.message.contains("away"))
        lock.dismissAutoLockNotice()
        #expect(lock.autoLockNotice == nil)
    }

    @Test @MainActor func mergeKeepsLocalAdoptsRemoteAndPrunes() {
        var local = VaultState()
        let shared = local.createFolder(named: "Shared")!
        let localOnly = local.createFolder(named: "Local", in: shared.id)!
        local.add(post("at://l"), in: localOnly.id)

        var synced = VaultState()
        synced.folders = [VaultFolder(id: shared.id, name: "Shared (renamed remotely)")]
        let remoteOnly = synced.createFolder(named: "Remote", in: shared.id)!
        let orphanParent = VaultFolder(name: "Orphan", parentID: UUID())
        synced.folders.append(orphanParent)
        synced.add(post("at://r"), in: remoteOnly.id)
        synced.add(post("at://l"), in: remoteOnly.id)          // conflicting filing
        synced.assignments["at://ghost"] = remoteOnly.id       // post that doesn't exist

        let merged = VaultState.merged(local: local, synced: synced)
        #expect(merged.folder(id: shared.id)?.name == "Shared")            // local wins
        #expect(merged.folder(id: remoteOnly.id) != nil)                    // adopted
        #expect(merged.folder(id: orphanParent.id)?.parentID == nil)        // re-rooted
        #expect(Set(merged.posts.map(\.uri)) == ["at://l", "at://r"])
        #expect(merged.folderID(forPostURI: "at://l") == localOnly.id)     // local filing wins
        #expect(merged.folderID(forPostURI: "at://r") == remoteOnly.id)
        #expect(merged.assignments["at://ghost"] == nil)
    }

    @Test @MainActor func storeSyncsThroughKVSAndMergesOnLoad() {
        let defaults = UserDefaults(suiteName: "atmo-vault-\(UUID().uuidString)")!
        let kvs = MemoryKeyValueStore()
        let store = VaultStore(defaults: defaults, syncedStore: kvs)
        let folder = store.createFolder(named: "Private")!
        store.createFolder(named: "Deeper", in: folder.id)
        #expect(!store.isEmpty)
        // Dual write: local defaults and the synced store both hold it.
        #expect(defaults.data(forKey: "com.atmo.app.vault") != nil)
        #expect(kvs.data(forKey: "com.atmo.app.vault") != nil)

        // A fresh device with only the synced copy comes up with the tree.
        let otherDevice = VaultStore(defaults: UserDefaults(suiteName: "atmo-vault-\(UUID().uuidString)")!, syncedStore: kvs)
        #expect(otherDevice.state.children(of: folder.id).map(\.name) == ["Deeper"])
    }
}

/// In-memory stand-in for iCloud KVS so store tests never touch the
/// developer's real defaults.
private final class MemoryKeyValueStore: SyncedKeyValueStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func string(forKey key: String) -> String? { storage[key].flatMap { String(data: $0, encoding: .utf8) } }
    func set(_ data: Data, forKey key: String) { storage[key] = data }
    func set(_ string: String, forKey key: String) { storage[key] = Data(string.utf8) }
    func removeValue(forKey key: String) { storage[key] = nil }
    func synchronize() {}
    func externalChanges() -> AsyncStream<[String]> { AsyncStream { $0.finish() } }
}
