import Foundation
import ATProtoKit

// MARK: - Platform seams
// AtmoCore is UI-framework-free and runs on Apple platforms and Linux.
// Anything that only exists on one platform family (Keychain, iCloud
// key-value store, Spotlight, app-lifecycle notifications) is reached
// through these protocols. Each app target installs its implementations
// once at launch:
//
//     Atmo.platform = .apple   // in the SwiftUI app
//     Atmo.platform = .linux   // in the GTK app
//
// The defaults below are portable no-op / UserDefaults fallbacks so the
// package always works standalone (e.g. under `swift test`).

// MARK: SecretsStoring

/// Stores the small pieces of session metadata Atmo keeps outside of
/// ATProtoKit's own credential store: the last signed-in handle and the
/// stable session UUID that namespaces ATProtoKit's keychain entries.
///
/// The Apple app backs this with the Keychain; the Linux app with a
/// protected file. The default implementation uses `UserDefaults` and is
/// intended for tests and development only.
public protocol SecretsStoring: Sendable {
    func saveLastHandle(_ handle: String)
    func loadLastHandle() -> String?
    /// A UUID that is generated once and then returned unchanged for the
    /// lifetime of the install. ATProtoKit stores the App Password and
    /// refresh token under `<uuid>.password` / `<uuid>.refreshToken`, so
    /// this value must be stable across launches or sessions are lost.
    func stableSessionUUID() -> UUID
    /// Removes everything (called on logout).
    func clearAll()
}

/// Portable fallback: keeps values in `UserDefaults`. Fine for tests and
/// development; app targets should install a protected implementation.
public struct UserDefaultsSecretsStore: SecretsStoring {
    private let handleKey = "atmo.last.handle"
    private let uuidKey = "atmo.atproto.session.uuid"

    public init() {}

    public func saveLastHandle(_ handle: String) {
        UserDefaults.standard.set(handle, forKey: handleKey)
    }

    public func loadLastHandle() -> String? {
        UserDefaults.standard.string(forKey: handleKey)
    }

    public func stableSessionUUID() -> UUID {
        if let stored = UserDefaults.standard.string(forKey: uuidKey),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: uuidKey)
        return fresh
    }

    public func clearAll() {
        UserDefaults.standard.removeObject(forKey: handleKey)
        UserDefaults.standard.removeObject(forKey: uuidKey)
    }
}

// MARK: SyncedKeyValueStore

/// A key-value store that may sync across the user's devices (iCloud KVS
/// on Apple platforms). Implementations fall back to local-only storage
/// where no sync service exists — callers treat sync as best-effort.
public protocol SyncedKeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func set(_ data: Data, forKey key: String)
    func set(_ string: String, forKey key: String)
    func removeValue(forKey key: String)
    /// Requests an immediate sync with the backing service, if any.
    func synchronize()
    /// Emits the batches of keys changed by an external device.
    /// Local-only implementations never emit.
    func externalChanges() -> AsyncStream<[String]>
}

/// Local-only fallback backed by `UserDefaults`; never emits external
/// changes. Used on Linux and in tests.
public struct LocalKeyValueStore: SyncedKeyValueStore {
    public init() {}

    public func data(forKey key: String) -> Data? { UserDefaults.standard.data(forKey: key) }
    public func string(forKey key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    public func set(_ data: Data, forKey key: String) { UserDefaults.standard.set(data, forKey: key) }
    public func set(_ string: String, forKey key: String) { UserDefaults.standard.set(string, forKey: key) }
    public func removeValue(forKey key: String) { UserDefaults.standard.removeObject(forKey: key) }
    public func synchronize() {}
    public func externalChanges() -> AsyncStream<[String]> {
        AsyncStream { _ in }
    }
}

// MARK: PostIndexing

/// Donates bookmarked posts to the system search index (Spotlight on
/// Apple platforms). Platforms without a system index install the no-op.
public protocol PostIndexing: Sendable {
    func index(_ bookmarks: [BookmarkedPost])
    func removeFromIndex(uris: [String])
}

public struct NoopPostIndexer: PostIndexing {
    public init() {}
    public func index(_ bookmarks: [BookmarkedPost]) {}
    public func removeFromIndex(uris: [String]) {}
}

// MARK: - AlertPresenting

/// Presents `FeedAlert`s produced by the background sync engine — local
/// user notifications on Apple platforms; a desktop-notification bridge
/// on Linux later. The no-op default swallows alerts.
public protocol AlertPresenting: Sendable {
    /// Ask the OS for permission to notify. Returns whether granted.
    func requestAuthorization() async -> Bool
    func present(_ alerts: [FeedAlert]) async
}

public struct NoopAlertPresenter: AlertPresenting {
    public init() {}
    public func requestAuthorization() async -> Bool { false }
    public func present(_ alerts: [FeedAlert]) async {}
}

// MARK: - SyncedFileStore

/// A cloud-synced file store for data too large for the synced key-value
/// store (iCloud KVS caps at 1 MB across all keys). The Apple app backs
/// this with the app's iCloud ubiquity container, storing OUTSIDE
/// Documents/ so files sync across devices but never appear in iCloud
/// Drive. The default no-op keeps AtmoCore portable — stores using this
/// seam must keep their own local baseline copy.
///
/// Conflict model: `readVersions` returns the current file plus any
/// unresolved conflict versions (two devices wrote concurrently); the
/// caller merges domain-aware (e.g. set-union by key) and writes back,
/// and `write` marks conflicts resolved.
public protocol SyncedFileStore: Sendable {
    /// The current contents plus any unresolved conflict versions.
    /// Empty when the file doesn't exist yet or sync is unavailable.
    func readVersions(name: String) async -> [Data]
    /// Replaces the file (best-effort; no-op when sync is unavailable)
    /// and marks any outstanding conflict versions resolved.
    func write(_ data: Data, name: String) async
    /// Emits whenever another device changes the file. Never emits when
    /// sync is unavailable.
    func externalChanges(name: String) -> AsyncStream<Void>
}

/// Default: no cloud file sync on this platform.
public struct NoopSyncedFileStore: SyncedFileStore {
    public init() {}
    public func readVersions(name: String) async -> [Data] { [] }
    public func write(_ data: Data, name: String) async {}
    public func externalChanges(name: String) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - PostMediaProcessing

/// Turns composer media references into upload-ready video bytes at
/// publish time. The composer holds only references (file URLs); nothing
/// is transcoded or rendered until the user hits Post — PostPublisher
/// resolves each reference through this seam.
///
/// The Apple app installs an AVFoundation-backed implementation; the
/// default refuses, which keeps AtmoCore portable (Linux, tests).
public protocol PostMediaProcessing: Sendable {
    /// Transcodes a picked video file into the format Bluesky's video
    /// service accepts (H.264 MP4 within the size/length limits).
    func prepareVideo(at url: URL) async throws -> PreparedUploadVideo
    /// Renders an audio take into a waveform video.
    func renderVoiceMemo(at url: URL) async throws -> PreparedUploadVideo
}

/// The publish-ready result of processing one media reference.
public struct PreparedUploadVideo: Sendable {
    public let data: Data
    public let fileName: String
    public let aspectRatio: (width: Int, height: Int)?

    public init(data: Data, fileName: String, aspectRatio: (width: Int, height: Int)?) {
        self.data = data
        self.fileName = fileName
        self.aspectRatio = aspectRatio
    }
}

/// Default: media publishing is unavailable on this platform.
public struct UnsupportedMediaProcessor: PostMediaProcessing {
    public struct Unsupported: Error {}
    public init() {}
    public func prepareVideo(at url: URL) async throws -> PreparedUploadVideo { throw Unsupported() }
    public func renderVoiceMemo(at url: URL) async throws -> PreparedUploadVideo { throw Unsupported() }
}

// MARK: - AtmoPlatform

/// The bundle of platform implementations AtmoCore's services use.
public struct AtmoPlatform: Sendable {
    public var secrets: any SecretsStoring
    public var syncedKeyValue: any SyncedKeyValueStore
    public var postIndexer: any PostIndexing
    /// Creates the store ATProtoKit persists the App Password and refresh
    /// token in. Called every time an `ATProtocolConfiguration` is built.
    public var makeCredentialStore: @Sendable () -> any ATCredentialStore
    /// The notification posted when the app returns to the foreground
    /// (`UIApplication.didBecomeActiveNotification` etc.); `nil` disables
    /// foreground-triggered refreshes.
    public var foregroundNotification: Notification.Name?
    /// The notification posted when the app leaves the foreground; when
    /// set, periodic polling pauses until the foreground notification
    /// fires again (battery: no timers while the user is away).
    public var backgroundNotification: Notification.Name?
    /// Seconds between silent timeline refresh checks.
    public var timelineRefreshInterval: TimeInterval
    /// Seconds between direct-message polls — deliberately shorter than
    /// the timeline interval, since a waiting message is time-sensitive.
    public var messagesRefreshInterval: TimeInterval
    /// Presents background-sync alerts to the user.
    public var alertPresenter: any AlertPresenting
    /// Resolves composer media references (video files, voice-memo audio)
    /// into upload-ready bytes at publish time.
    public var mediaProcessor: any PostMediaProcessing
    /// Cloud-synced file storage for data beyond the KVS size budget
    /// (the Liked history). Hidden from user-visible cloud storage.
    public var syncedFiles: any SyncedFileStore

    public init(
        secrets: any SecretsStoring = UserDefaultsSecretsStore(),
        syncedKeyValue: any SyncedKeyValueStore = LocalKeyValueStore(),
        postIndexer: any PostIndexing = NoopPostIndexer(),
        makeCredentialStore: @escaping @Sendable () -> any ATCredentialStore,
        foregroundNotification: Notification.Name? = nil,
        backgroundNotification: Notification.Name? = nil,
        timelineRefreshInterval: TimeInterval = 3 * 60,
        messagesRefreshInterval: TimeInterval = 45,
        alertPresenter: any AlertPresenting = NoopAlertPresenter(),
        mediaProcessor: any PostMediaProcessing = UnsupportedMediaProcessor(),
        syncedFiles: any SyncedFileStore = NoopSyncedFileStore()
    ) {
        self.secrets = secrets
        self.syncedKeyValue = syncedKeyValue
        self.postIndexer = postIndexer
        self.makeCredentialStore = makeCredentialStore
        self.foregroundNotification = foregroundNotification
        self.backgroundNotification = backgroundNotification
        self.timelineRefreshInterval = timelineRefreshInterval
        self.messagesRefreshInterval = messagesRefreshInterval
        self.alertPresenter = alertPresenter
        self.mediaProcessor = mediaProcessor
        self.syncedFiles = syncedFiles
    }

    /// Portable default: file-backed credential storage next to the other
    /// defaults above. App targets replace this wholesale at launch.
    public static var fallback: AtmoPlatform {
        AtmoPlatform(makeCredentialStore: { FileCredentialStore() })
    }
}

/// Global access point for the installed platform implementations.
/// Set `Atmo.platform` once, at launch, before any AtmoCore service is
/// touched — the stores are singletons that capture it on first use.
@MainActor
public enum Atmo {
    public static var platform: AtmoPlatform = .fallback
}
