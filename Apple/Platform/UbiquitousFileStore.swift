// The watch target compiles this directory but ships without iCloud
// entitlements (see project.yml) — it installs NoopSyncedFileStore, and
// this implementation stays out of its build entirely.
#if !os(watchOS)
import Foundation
import AtmoCore

// MARK: - Ubiquitous File Store
/// AtmoCore's SyncedFileStore backed by the app's iCloud ubiquity
/// container. Files live under `<container>/SyncData/` — deliberately
/// OUTSIDE Documents/, so they sync across the user's devices but never
/// appear in iCloud Drive or the Files app.
///
/// Degrades to a no-op when iCloud is unavailable (signed out, or the
/// entitlement is absent): reads return nothing, writes vanish, and the
/// change stream finishes immediately — callers keep their local copy.
///
/// Conflicts: concurrent writes from two devices surface as
/// NSFileVersion conflict versions. `readVersions` hands every version's
/// bytes to the caller (whose merge is domain-aware); `write` stores the
/// resolution and marks the conflicts resolved.
nonisolated struct UbiquitousFileStore: SyncedFileStore {

    private static let subdirectory = "SyncData"

    /// Resolved once per launch; `url(forUbiquityContainerIdentifier:)`
    /// can block briefly, so first access happens off the main actor
    /// (all call sites below are detached or background).
    private static let containerURL: URL? = {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }()

    private static func fileURL(name: String) -> URL? {
        guard let container = containerURL else { return nil }
        let directory = container.appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    func readVersions(name: String) async -> [Data] {
        await Task.detached(priority: .utility) {
            guard let url = Self.fileURL(name: name) else { return [] }

            // A not-yet-local file downloads in the background; the
            // metadata stream fires again once it lands.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)

            var versions: [Data] = []
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                if let data = try? Data(contentsOf: readURL) {
                    versions.append(data)
                }
            }
            for conflict in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                if let data = try? Data(contentsOf: conflict.url) {
                    versions.append(data)
                }
            }
            return versions
        }.value
    }

    func write(_ data: Data, name: String) async {
        await Task.detached(priority: .utility) {
            guard let url = Self.fileURL(name: name) else { return }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
                try? data.write(to: writeURL, options: .atomic)
            }
            // The written data IS the merge of every version — retire them.
            if let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty {
                for version in conflicts {
                    version.isResolved = true
                }
                try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            }
        }.value
    }

    func externalChanges(name: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            Task {
                // Container resolution off-main; no container → no stream.
                let available = await Task.detached(priority: .utility) {
                    Self.containerURL != nil
                }.value
                guard available else {
                    continuation.finish()
                    return
                }
                let observer = await MainActor.run {
                    let observer = UbiquitousFileObserver(fileName: name) {
                        continuation.yield(())
                    }
                    observer.start()
                    return observer
                }
                continuation.onTermination = { _ in
                    Task { @MainActor in
                        observer.stop()
                    }
                }
            }
        }
    }
}

// MARK: - Metadata Observer
/// NSMetadataQuery wrapper watching one file in the ubiquity data scope
/// (the non-Documents container area). Fires the callback on every
/// remote-driven update and keeps not-yet-local updates downloading.
@MainActor
private final class UbiquitousFileObserver {
    private let query = NSMetadataQuery()
    private let onChange: () -> Void
    private var observers: [NSObjectProtocol] = []

    init(fileName: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, fileName)
    }

    func start() {
        let names: [Notification.Name] = [
            .NSMetadataQueryDidFinishGathering,
            .NSMetadataQueryDidUpdate,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: query,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleQueryEvent()
                }
            })
        }
        query.start()
    }

    func stop() {
        query.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleQueryEvent() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        // Kick downloads for updates that only exist in the cloud so the
        // subsequent read sees real bytes.
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        onChange()
    }
}
#endif
