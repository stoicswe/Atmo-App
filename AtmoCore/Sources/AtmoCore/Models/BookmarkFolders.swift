import Foundation

// MARK: - Bookmark Folder
/// One user-created folder for organizing bookmarks.
public struct BookmarkFolder: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

// MARK: - Bookmark Folder State
/// Pure value core of the folder system: the folders plus a
/// bookmark-URI → folder-id assignment map (absent = unfiled). All the
/// mutation and merge rules live here so they're directly unit-testable;
/// BookmarkFolderStore wraps this with persistence and sync.
public struct BookmarkFolderState: Codable, Equatable, Sendable {
    public var folders: [BookmarkFolder]
    /// Bookmark URI → folder id. A bookmark lives in at most one folder;
    /// no entry means it sits at the top level ("unfiled").
    public var assignments: [String: UUID]

    public init(folders: [BookmarkFolder] = [], assignments: [String: UUID] = [:]) {
        self.folders = folders
        self.assignments = assignments
    }

    /// Display order: alphabetical, case-insensitive — stable across
    /// devices regardless of creation interleaving.
    public var sortedFolders: [BookmarkFolder] {
        folders.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func folder(id: UUID) -> BookmarkFolder? {
        folders.first { $0.id == id }
    }

    // MARK: Mutations

    /// Creates a folder; whitespace-only names are refused.
    @discardableResult
    public mutating func createFolder(named rawName: String) -> BookmarkFolder? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let folder = BookmarkFolder(name: name)
        folders.append(folder)
        return folder
    }

    /// Renames a folder; whitespace-only names are refused (no-op).
    public mutating func renameFolder(id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
    }

    /// Deletes a folder; its bookmarks return to the top level.
    public mutating func deleteFolder(id: UUID) {
        folders.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
    }

    /// Files a bookmark into a folder, or back to the top level (nil).
    /// Filing into a folder that doesn't exist unfiles instead — an
    /// assignment must never point at nothing.
    public mutating func move(bookmarkURI uri: String, to folderID: UUID?) {
        if let folderID, folders.contains(where: { $0.id == folderID }) {
            assignments[uri] = folderID
        } else {
            assignments.removeValue(forKey: uri)
        }
    }

    /// Drops assignments for bookmarks that no longer exist.
    public mutating func pruneAssignments(keeping bookmarkURIs: Set<String>) {
        assignments = assignments.filter { bookmarkURIs.contains($0.key) }
    }

    // MARK: Queries

    public func folderID(forBookmarkURI uri: String) -> UUID? {
        assignments[uri]
    }

    /// The bookmarks filed in `folderID` (nil = the unfiled top level),
    /// preserving the order of `all`.
    public func bookmarks(in folderID: UUID?, from all: [BookmarkedPost]) -> [BookmarkedPost] {
        all.filter { assignments[$0.uri] == folderID }
    }

    /// How many of `all` are filed in the folder.
    public func count(in folderID: UUID, from all: [BookmarkedPost]) -> Int {
        all.reduce(0) { $0 + (assignments[$1.uri] == folderID ? 1 : 0) }
    }

    // MARK: Cross-device merge

    /// Local-primary merge, mirroring BookmarkStore: keep every local
    /// folder (local rename wins), adopt synced-only folders, then union
    /// assignments with local winning conflicts — and drop any assignment
    /// pointing at a folder that didn't survive.
    public static func merged(local: BookmarkFolderState, synced: BookmarkFolderState) -> BookmarkFolderState {
        var result = local
        let localIDs = Set(local.folders.map(\.id))
        result.folders += synced.folders.filter { !localIDs.contains($0.id) }

        for (uri, folderID) in synced.assignments where result.assignments[uri] == nil {
            result.assignments[uri] = folderID
        }
        let folderIDs = Set(result.folders.map(\.id))
        result.assignments = result.assignments.filter { folderIDs.contains($0.value) }
        return result
    }
}
