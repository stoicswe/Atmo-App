import Foundation

// MARK: - Composer Media Files
/// File storage backing composer attachments and draft media: video and
/// voice-memo references live here from attach time (so drafts can point
/// at them and system temp cleanup can't eat them), and draft image data
/// is written here on save, keyed by attachment id.
///
/// Lifecycle: PostPublisher deletes a video file after its post goes out;
/// DraftStore deletes a draft's files when the draft is deleted; and an
/// orphan sweep at launch removes anything unreferenced and old enough
/// that no live composer can still own it.
public enum ComposerMediaFiles {

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Atmo/ComposerMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Videos / memos (files owned from attach time)

    /// A fresh composer-owned destination for an attached video or memo.
    public static func newVideoURL(fileExtension: String) -> URL {
        let ext = fileExtension.isEmpty ? "bin" : fileExtension
        return directory.appendingPathComponent("vid-\(UUID().uuidString).\(ext)")
    }

    // MARK: Draft images (data keyed by attachment id)

    public static func imageURL(for id: UUID) -> URL {
        directory.appendingPathComponent("img-\(id.uuidString).bin")
    }

    public static func saveImage(_ data: Data, id: UUID) {
        try? data.write(to: imageURL(for: id), options: .atomic)
    }

    public static func loadImage(id: UUID) -> Data? {
        try? Data(contentsOf: imageURL(for: id))
    }

    public static func deleteImage(id: UUID) {
        try? FileManager.default.removeItem(at: imageURL(for: id))
    }

    public static func delete(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: Orphan sweep

    /// Removes files not referenced by any draft, old enough (default two
    /// days) that no live composer session can still own them. The age
    /// guard protects freshly attached media that hasn't been drafted yet.
    public static func pruneOrphans(
        referencedPaths: Set<String>,
        olderThan age: TimeInterval = 2 * 86_400,
        now: Date = Date()
    ) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for file in files where !referencedPaths.contains(file.path) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > age {
                try? manager.removeItem(at: file)
            }
        }
    }
}
