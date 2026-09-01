import Foundation
import Observation

// MARK: - Bookmark Folder Store
/// Persists the bookmark folder structure with the same dual-write
/// strategy as BookmarkStore: UserDefaults locally (always available),
/// plus the platform's synced key-value store — iCloud KVS on Apple
/// platforms, which syncs across the user's devices without ever
/// appearing in iCloud Drive.
///
/// All folder/assignment rules live in BookmarkFolderState (pure, unit
/// tested); this class adds persistence, cross-device merge, and change
/// observation.
@Observable
@MainActor
public final class BookmarkFolderStore {

    public static let shared = BookmarkFolderStore()

    // MARK: State

    public private(set) var state = BookmarkFolderState()

    /// Folders in display order (alphabetical, case-insensitive).
    public var folders: [BookmarkFolder] { state.sortedFolders }

    // MARK: Private

    private let syncedStore = Atmo.platform.syncedKeyValue
    private let storeKey = "com.atmo.app.bookmarkFolders"
    private var externalChangeTask: Task<Void, Never>? = nil

    private init() {
        load()
        startObservingRemoteChanges()
    }

    // MARK: - Mutations (persisting wrappers over the value core)

    @discardableResult
    public func createFolder(named name: String) -> BookmarkFolder? {
        guard let folder = state.createFolder(named: name) else { return nil }
        persist()
        return folder
    }

    public func renameFolder(id: UUID, to name: String) {
        state.renameFolder(id: id, to: name)
        persist()
    }

    /// Deletes the folder; its bookmarks return to the top level.
    public func deleteFolder(id: UUID) {
        state.deleteFolder(id: id)
        persist()
    }

    /// Files a bookmark into a folder (nil = back to the top level).
    public func move(bookmarkURI uri: String, to folderID: UUID?) {
        state.move(bookmarkURI: uri, to: folderID)
        persist()
    }

    /// Drops assignments for bookmarks that no longer exist. Persists only
    /// when something actually changed, so callers can invoke it freely.
    public func pruneAssignments(keeping bookmarkURIs: Set<String>) {
        let before = state.assignments.count
        state.pruneAssignments(keeping: bookmarkURIs)
        if state.assignments.count != before {
            persist()
        }
    }

    // MARK: - Persistence

    private func load() {
        let local = decode(UserDefaults.standard.data(forKey: storeKey)) ?? BookmarkFolderState()
        let synced = decode(syncedStore.data(forKey: storeKey)) ?? BookmarkFolderState()
        let merged = BookmarkFolderState.merged(local: local, synced: synced)
        state = merged
        // Backfill local storage when sync contributed anything new.
        if merged != local {
            saveLocal(merged)
        }
    }

    private func persist() {
        saveLocal(state)
        if let data = encode(state) {
            syncedStore.set(data, forKey: storeKey)
            syncedStore.synchronize()
        }
    }

    private func saveLocal(_ value: BookmarkFolderState) {
        guard let data = encode(value) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private func encode(_ value: BookmarkFolderState) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    private func decode(_ data: Data?) -> BookmarkFolderState? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BookmarkFolderState.self, from: data)
    }

    // MARK: - Remote Change Observation
    // Same pattern as BookmarkStore: reload (merging) on the next
    // main-actor tick when another device pushes a change.
    private func startObservingRemoteChanges() {
        let key = storeKey
        let changes = syncedStore.externalChanges()
        externalChangeTask = Task { [weak self] in
            for await changedKeys in changes {
                guard changedKeys.contains(key) else { continue }
                Task { @MainActor [weak self] in
                    self?.load()
                }
            }
        }
    }
}
