import Foundation

// MARK: - Vault Folder
/// A folder inside the Vault. Unlike bookmark folders these nest:
/// `parentID` nil is the vault's top level.
public struct VaultFolder: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

// MARK: - Vault State
/// The pure value core of the Vault: the posts kept inside it, its folder
/// tree, and which folder each post is filed in (absent = top level).
/// Every mutation is a plain value operation, unit-tested; VaultStore
/// adds persistence and the lock around it.
public struct VaultState: Codable, Equatable, Sendable {
    public var posts: [BookmarkedPost]
    public var folders: [VaultFolder]
    /// Post URI → folder. Missing means the vault's top level.
    public var assignments: [String: UUID]

    public init(posts: [BookmarkedPost] = [], folders: [VaultFolder] = [], assignments: [String: UUID] = [:]) {
        self.posts = posts
        self.folders = folders
        self.assignments = assignments
    }

    // MARK: Posts

    public func contains(uri: String) -> Bool {
        posts.contains { $0.uri == uri }
    }

    /// Adds a post (newest first) into `folderID`; a repeat only re-files it.
    public mutating func add(_ post: BookmarkedPost, in folderID: UUID? = nil) {
        if !contains(uri: post.uri) {
            posts.insert(post, at: 0)
        }
        move(postURI: post.uri, to: folderID)
    }

    @discardableResult
    public mutating func remove(uri: String) -> BookmarkedPost? {
        guard let index = posts.firstIndex(where: { $0.uri == uri }) else { return nil }
        assignments[uri] = nil
        return posts.remove(at: index)
    }

    /// Files a post into a folder (nil = top level). Unknown folders are
    /// treated as the top level so a stale id can't strand a post.
    public mutating func move(postURI uri: String, to folderID: UUID?) {
        if let folderID, folder(id: folderID) != nil {
            assignments[uri] = folderID
        } else {
            assignments[uri] = nil
        }
    }

    public func folderID(forPostURI uri: String) -> UUID? {
        assignments[uri]
    }

    /// Posts filed directly in `folderID` (nil = top level), newest first.
    public func posts(in folderID: UUID?) -> [BookmarkedPost] {
        posts.filter { assignments[$0.uri] == folderID }
    }

    // MARK: Folders

    public func folder(id: UUID) -> VaultFolder? {
        folders.first { $0.id == id }
    }

    /// Direct subfolders of `parentID` (nil = top level), by name.
    public func children(of parentID: UUID?) -> [VaultFolder] {
        folders
            .filter { $0.parentID == parentID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Top level → … → `folderID`, for a breadcrumb.
    public func path(to folderID: UUID?) -> [VaultFolder] {
        var chain: [VaultFolder] = []
        var current = folderID
        var guardCount = 0
        while let id = current, let folder = folder(id: id), guardCount < 64 {
            chain.insert(folder, at: 0)
            current = folder.parentID
            guardCount += 1
        }
        return chain
    }

    /// `candidate` is `folderID` itself or somewhere beneath it.
    public func isSameOrDescendant(_ candidate: UUID, of folderID: UUID) -> Bool {
        var current: UUID? = candidate
        var guardCount = 0
        while let id = current, guardCount < 64 {
            if id == folderID { return true }
            current = folder(id: id)?.parentID
            guardCount += 1
        }
        return false
    }

    /// Posts in `folderID` and every folder beneath it.
    public func count(in folderID: UUID) -> Int {
        assignments.values.filter { isSameOrDescendant($0, of: folderID) }.count
    }

    /// Every folder in display order with its depth, for a "Move To" list.
    public func flattened(from parentID: UUID? = nil, depth: Int = 0) -> [(folder: VaultFolder, depth: Int)] {
        children(of: parentID).flatMap { child in
            [(child, depth)] + flattened(from: child.id, depth: depth + 1)
        }
    }

    @discardableResult
    public mutating func createFolder(named rawName: String, in parentID: UUID? = nil) -> VaultFolder? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let parentID, folder(id: parentID) == nil { return nil }
        let folder = VaultFolder(name: name, parentID: parentID)
        folders.append(folder)
        return folder
    }

    public mutating func renameFolder(id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
    }

    /// Removes the folder and everything beneath it; their posts move up
    /// to the deleted folder's parent — nothing in the vault is lost.
    public mutating func deleteFolder(id: UUID) {
        guard let target = folder(id: id) else { return }
        let doomed = Set(folders.filter { isSameOrDescendant($0.id, of: id) }.map(\.id))
        for (uri, folderID) in assignments where doomed.contains(folderID) {
            assignments[uri] = target.parentID
        }
        folders.removeAll { doomed.contains($0.id) }
    }

    /// Local-primary cross-device merge, the bookmark rule applied to the
    /// Vault: keep every local post and folder (local edits win), adopt
    /// what only the other device has, then union the filing with local
    /// winning conflicts. Anything pointing at a folder or post that
    /// didn't survive is dropped, and a folder whose parent is gone moves
    /// to the top level. Pure; unit-tested.
    public static func merged(local: VaultState, synced: VaultState) -> VaultState {
        var result = local

        let localURIs = Set(local.posts.map(\.uri))
        result.posts += synced.posts.filter { !localURIs.contains($0.uri) }
        result.posts.sort { $0.bookmarkedAt > $1.bookmarkedAt }

        let localFolderIDs = Set(local.folders.map(\.id))
        result.folders += synced.folders.filter { !localFolderIDs.contains($0.id) }
        let folderIDs = Set(result.folders.map(\.id))
        for index in result.folders.indices {
            if let parent = result.folders[index].parentID, !folderIDs.contains(parent) {
                result.folders[index].parentID = nil
            }
        }

        for (uri, folderID) in synced.assignments where result.assignments[uri] == nil {
            result.assignments[uri] = folderID
        }
        let postURIs = Set(result.posts.map(\.uri))
        result.assignments = result.assignments.filter { postURIs.contains($0.key) && folderIDs.contains($0.value) }
        return result
    }

    /// Re-parents a folder; refused when it would create a cycle.
    public mutating func moveFolder(id: UUID, to newParentID: UUID?) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        if let newParentID {
            guard folder(id: newParentID) != nil, !isSameOrDescendant(newParentID, of: id) else { return }
        }
        folders[index].parentID = newParentID
    }
}

// MARK: - Vault Unlock Duration
/// How long the Vault stays open after Face ID / Touch ID / passcode,
/// chosen in Settings → Family. Leaving the app always locks it.
public enum VaultUnlockDuration: String, CaseIterable, Identifiable, Sendable {
    case everyTime
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    public static let storageKey = "atmo.vault.unlockDuration"
    public static let defaultValue: VaultUnlockDuration = .fiveMinutes

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .everyTime:      return "Every time"
        case .oneMinute:      return "1 minute"
        case .fiveMinutes:    return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour:        return "1 hour"
        }
    }

    /// Nil means re-authenticate on every open.
    public var seconds: TimeInterval? {
        switch self {
        case .everyTime:      return nil
        case .oneMinute:      return 60
        case .fiveMinutes:    return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .oneHour:        return 60 * 60
        }
    }

    public static func stored(rawValue: String?) -> VaultUnlockDuration {
        rawValue.flatMap(VaultUnlockDuration.init(rawValue:)) ?? defaultValue
    }
}
