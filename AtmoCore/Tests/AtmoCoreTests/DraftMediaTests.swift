import Foundation
import Testing
@testable import AtmoCore

/// Covers draft media persistence: model back-compat, media-aware exit
/// policy, the composer media file store, and DraftStore's file cleanup.
/// Serialized: these tests share the real composer media directory, and
/// the orphan-sweep test deletes unreferenced files — running them in
/// parallel lets the sweep eat a sibling test's fixtures.
@Suite(.serialized)
struct DraftMediaTests {

    // MARK: - Model

    @Test func oldDraftJSONWithoutMediaKeysStillDecodes() throws {
        let legacy = """
        {"id":"9E9679B0-9C95-4231-A17D-8A1B4F2C6D5E","text":"hello",
         "attachedImageFileNames":["a.jpg"]}
        """.data(using: .utf8)!
        let post = try JSONDecoder().decode(DraftPost.self, from: legacy)
        #expect(post.text == "hello")
        #expect(post.attachedImageFileNames == ["a.jpg"])
        #expect(post.images.isEmpty)
        #expect(post.video == nil)
    }

    @Test func mediaOnlyDraftIsNotEmpty() {
        let imageOnly = ComposerDraft(posts: [
            DraftPost(text: "", images: [DraftImageRef(id: UUID(), fileName: "x.jpg")])
        ])
        #expect(!imageOnly.isEmpty)

        let videoOnly = ComposerDraft(posts: [
            DraftPost(text: "", video: DraftVideoRef(kind: .voiceMemo, filePath: "/tmp/x.m4a"))
        ])
        #expect(!videoOnly.isEmpty)

        let bare = ComposerDraft(posts: [DraftPost(text: "  ")])
        #expect(bare.isEmpty)
    }

    // MARK: - Exit policy counts media

    @MainActor
    @Test func mediaOnlySlotsCountAsContent() {
        #expect(ComposerViewModel.exitDraftPolicy(forContentfulSlots: [true]) == .promptToSave)
        #expect(ComposerViewModel.exitDraftPolicy(forContentfulSlots: [true, true]) == .autoSave)
        #expect(ComposerViewModel.exitDraftPolicy(forContentfulSlots: [false, false]) == .discardSilently)
        // The text-only convenience still matches the old behavior.
        #expect(ComposerViewModel.exitDraftPolicy(forSlotTexts: ["hi", ""]) == .promptToSave)
    }

    // MARK: - Media file store

    @Test func imageDataRoundTripsThroughMediaStore() {
        let id = UUID()
        let payload = Data([9, 8, 7, 6])
        ComposerMediaFiles.saveImage(payload, id: id)
        #expect(ComposerMediaFiles.loadImage(id: id) == payload)
        ComposerMediaFiles.deleteImage(id: id)
        #expect(ComposerMediaFiles.loadImage(id: id) == nil)
    }

    // MARK: - DraftStore file cleanup

    @MainActor
    @Test func deleteRemovesImageFilesAndHonorsVideoPreservation() throws {
        let suite = UserDefaults(suiteName: "DraftMediaTests-\(UUID().uuidString)")!
        let store = DraftStore(defaults: suite)

        let imageID = UUID()
        ComposerMediaFiles.saveImage(Data([1, 2, 3]), id: imageID)
        let videoURL = ComposerMediaFiles.newVideoURL(fileExtension: "mov")
        try Data([4, 5, 6]).write(to: videoURL)

        func makeDraft() -> ComposerDraft {
            ComposerDraft(posts: [DraftPost(
                text: "with media",
                images: [DraftImageRef(id: imageID, fileName: "a.jpg")],
                video: DraftVideoRef(kind: .video, filePath: videoURL.path)
            )])
        }

        // Submission path: image file goes, the publisher's video stays.
        let first = makeDraft()
        store.save(first)
        store.delete(id: first.id, preservingVideoFile: true)
        #expect(ComposerMediaFiles.loadImage(id: imageID) == nil)
        #expect(FileManager.default.fileExists(atPath: videoURL.path))

        // Plain deletion: everything goes.
        ComposerMediaFiles.saveImage(Data([1, 2, 3]), id: imageID)
        let second = makeDraft()
        store.save(second)
        store.delete(id: second.id)
        #expect(ComposerMediaFiles.loadImage(id: imageID) == nil)
        #expect(!FileManager.default.fileExists(atPath: videoURL.path))
    }

    // MARK: - Orphan sweep

    @Test func orphanSweepSparesReferencedAndFreshFiles() throws {
        let referenced = ComposerMediaFiles.newVideoURL(fileExtension: "mov")
        let freshOrphan = ComposerMediaFiles.newVideoURL(fileExtension: "mov")
        try Data([1]).write(to: referenced)
        try Data([2]).write(to: freshOrphan)

        // Both files are brand new — even the unreferenced one survives
        // the age guard (a live composer session could still own it).
        ComposerMediaFiles.pruneOrphans(referencedPaths: [referenced.path])
        #expect(FileManager.default.fileExists(atPath: referenced.path))
        #expect(FileManager.default.fileExists(atPath: freshOrphan.path))

        // Pretend time passed: with the age guard at zero, the orphan
        // goes and the referenced file still survives.
        ComposerMediaFiles.pruneOrphans(
            referencedPaths: [referenced.path],
            olderThan: 0,
            now: Date().addingTimeInterval(60)
        )
        #expect(FileManager.default.fileExists(atPath: referenced.path))
        #expect(!FileManager.default.fileExists(atPath: freshOrphan.path))

        try? FileManager.default.removeItem(at: referenced)
    }
}
