import Foundation
import Observation

// MARK: - Vault Authentication seam
/// Owner verification for the Vault — Face ID / Touch ID with the device
/// passcode (or account password) as the fallback on Apple platforms.
public protocol VaultAuthenticating: Sendable {
    /// Whether this device can verify its owner at all.
    var isAvailable: Bool { get }
    /// Prompts; true on success.
    func authenticate(reason: String) async -> Bool
}

/// Platforms without owner verification: the Vault stays unavailable.
public struct UnavailableVaultAuthenticator: VaultAuthenticating {
    public init() {}
    public var isAvailable: Bool { false }
    public func authenticate(reason: String) async -> Bool { false }
}

// MARK: - Vault Store
/// The private section of Bookmarks. Persists like the bookmark stores —
/// UserDefaults locally plus the platform's synced key-value store, so
/// the Vault follows the person across their devices through iCloud —
/// but with one deliberate difference: its posts are never donated to
/// Spotlight or any search index. Readable through the UI only while
/// `VaultLock` is open. Posts move in from bookmarks and back out;
/// inside, they file into nested folders.
@Observable
@MainActor
public final class VaultStore {

    public static let shared = VaultStore()

    public private(set) var state = VaultState()

    private let defaults: UserDefaults
    private let syncedStore: any SyncedKeyValueStore
    private let storeKey = "com.atmo.app.vault"
    private var externalChangeTask: Task<Void, Never>? = nil

    /// Internal so tests can point the store at scratch storage.
    init(
        defaults: UserDefaults = .standard,
        syncedStore: any SyncedKeyValueStore = Atmo.platform.syncedKeyValue
    ) {
        self.defaults = defaults
        self.syncedStore = syncedStore
        load()
        startObservingRemoteChanges()
    }

    public var isEmpty: Bool { state.posts.isEmpty && state.folders.isEmpty }

    public func contains(uri: String) -> Bool { state.contains(uri: uri) }

    // MARK: Moving in and out

    /// Takes a bookmark into the Vault: it leaves the bookmark list (and
    /// with it the search index) and lands in `folderID`.
    public func moveIntoVault(_ bookmark: BookmarkedPost, in folderID: UUID? = nil) {
        state.add(bookmark, in: folderID)
        BookmarkStore.shared.remove(uri: bookmark.uri)
        persist()
    }

    /// Sends a post back to ordinary bookmarks.
    public func moveOutOfVault(uri: String) {
        guard let post = state.remove(uri: uri) else { return }
        BookmarkStore.shared.add(post)
        persist()
    }

    /// Drops a post from the Vault entirely.
    public func remove(uri: String) {
        state.remove(uri: uri)
        persist()
    }

    public func move(postURI uri: String, to folderID: UUID?) {
        state.move(postURI: uri, to: folderID)
        persist()
    }

    // MARK: Folders

    @discardableResult
    public func createFolder(named name: String, in parentID: UUID? = nil) -> VaultFolder? {
        let folder = state.createFolder(named: name, in: parentID)
        if folder != nil { persist() }
        return folder
    }

    public func renameFolder(id: UUID, to name: String) {
        state.renameFolder(id: id, to: name)
        persist()
    }

    public func deleteFolder(id: UUID) {
        state.deleteFolder(id: id)
        persist()
    }

    public func moveFolder(id: UUID, to parentID: UUID?) {
        state.moveFolder(id: id, to: parentID)
        persist()
    }

    // MARK: Persistence — dual write, local-primary merge on load

    private func load() {
        let local = decode(defaults.data(forKey: storeKey)) ?? VaultState()
        let synced = decode(syncedStore.data(forKey: storeKey)) ?? VaultState()
        let merged = VaultState.merged(local: local, synced: synced)
        state = merged
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

    private func saveLocal(_ value: VaultState) {
        guard let data = encode(value) else { return }
        defaults.set(data, forKey: storeKey)
    }

    private func encode(_ value: VaultState) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    private func decode(_ data: Data?) -> VaultState? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VaultState.self, from: data)
    }

    /// Another device changed the Vault: reload (merging) on the next
    /// main-actor tick. Still nothing goes near the search index.
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

// MARK: - Vault Lock
/// Whether the Vault is currently open, and for how long. Opening runs
/// the platform's owner verification; the unlock then lasts the duration
/// chosen in Settings (or a single visit), and leaving the app locks it
/// regardless.
@Observable
@MainActor
public final class VaultLock {

    public static let shared = VaultLock()

    /// Nil while locked.
    public private(set) var unlockedUntil: Date? = nil
    public private(set) var isAuthenticating = false
    /// The first-use explanation has been shown and accepted.
    public private(set) var hasCompletedSetup: Bool
    /// Set when the Vault locked on its own — the timer ran out or the
    /// app was left — so the UI can say so. Cleared by `dismissAutoLockNotice`.
    public private(set) var autoLockNotice: AutoLockReason? = nil

    public enum AutoLockReason: Sendable, Equatable {
        case timerExpired
        case leftApp

        public var message: String {
            switch self {
            case .timerExpired: return "Vault locked — unlock time ran out"
            case .leftApp:      return "Vault locked while you were away"
            }
        }
    }

    private let defaults: UserDefaults
    private let setupKey = "atmo.vault.setupComplete"
    /// Fires the timed re-lock (and its notice) at expiry.
    @ObservationIgnored private var expiryTask: Task<Void, Never>? = nil

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedSetup = defaults.bool(forKey: setupKey)
    }

    public var duration: VaultUnlockDuration {
        VaultUnlockDuration.stored(rawValue: defaults.string(forKey: VaultUnlockDuration.storageKey))
    }

    public func setDuration(_ duration: VaultUnlockDuration) {
        defaults.set(duration.rawValue, forKey: VaultUnlockDuration.storageKey)
    }

    public var isAvailable: Bool { Atmo.platform.vaultAuthenticator.isAvailable }

    public var isUnlocked: Bool {
        Self.isUnlocked(until: unlockedUntil, now: Date())
    }

    /// Pure expiry rule: open while `until` is in the future. Unit-tested.
    nonisolated public static func isUnlocked(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return until > now
    }

    /// Expiry for an unlock happening at `now` under `duration`. "Every
    /// time" still keeps the vault open for the visit (a generous window
    /// that `lockOnLeave` cuts short the moment the person navigates away).
    nonisolated public static func expiry(for duration: VaultUnlockDuration, from now: Date) -> Date {
        now.addingTimeInterval(duration.seconds ?? 12 * 60 * 60)
    }

    /// Verifies the owner and opens the Vault. False when refused or
    /// unavailable.
    @discardableResult
    public func unlock(reason: String = "Unlock your Vault") async -> Bool {
        guard !isAuthenticating else { return isUnlocked }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let ok = await Atmo.platform.vaultAuthenticator.authenticate(reason: reason)
        if ok {
            let until = Self.expiry(for: duration, from: Date())
            unlockedUntil = until
            autoLockNotice = nil
            markSetupComplete()
            scheduleExpiry(at: until)
        }
        return ok
    }

    /// Manual lock (the lock button, Settings): silent.
    public func lock() {
        expiryTask?.cancel()
        expiryTask = nil
        unlockedUntil = nil
    }

    /// The app left the foreground: lock, and say so on return — but only
    /// if the Vault was actually open.
    public func lockForLeavingApp() {
        guard isUnlocked else { return }
        lock()
        autoLockNotice = .leftApp
    }

    /// Called when the Vault screen is left: "Every time" relocks here
    /// (silently — that's the chosen behaviour); timed durations keep
    /// counting down.
    public func lockOnLeave() {
        if duration == .everyTime { lock() }
    }

    public func dismissAutoLockNotice() {
        autoLockNotice = nil
    }

    /// Wakes at expiry to flip the state and raise the notice, so a Vault
    /// left open re-locks visibly instead of just failing the next read.
    private func scheduleExpiry(at until: Date) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            let delay = until.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self, self.unlockedUntil == until else { return }
            self.unlockedUntil = nil
            self.autoLockNotice = .timerExpired
        }
    }

    public func markSetupComplete() {
        guard !hasCompletedSetup else { return }
        hasCompletedSetup = true
        defaults.set(true, forKey: setupKey)
    }
}
