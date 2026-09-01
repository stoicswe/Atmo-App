import Foundation
import ATProtoKit
import Observation

// MARK: - PostSlot
// Represents one post in a thread being composed. Each slot has its own
// text, image attachments, and character count — and is rendered as a
// separate row in the thread composer UI.
@Observable
@MainActor
public final class PostSlot: Identifiable {
    public let id: UUID
    public var text: String = "" {
        didSet { onTextChanged?() }
    }
    public var attachedImages: [ImageAttachment] = []
    /// One video per post, mutually exclusive with images (Bluesky's rule).
    public var attachedVideo: VideoAttachment? = nil

    /// Fired whenever text changes — wired by ComposerViewModel for draft auto-save.
    public var onTextChanged: (() -> Void)? = nil

    /// Fired whenever attachments change — wired by ComposerViewModel so
    /// drafts track media edits (drafts persist media references now).
    public var onMediaChanged: (() -> Void)? = nil

    public struct ImageAttachment: Identifiable {
        public let id = UUID()
        public let data: Data
        public let fileName: String
        public var altText: String = ""

        public init(data: Data, fileName: String, altText: String = "") {
            self.data = data
            self.fileName = fileName
            self.altText = altText
        }
    }

    /// A video attachment held as a *reference* — nothing is transcoded or
    /// rendered while composing. PostPublisher resolves the reference into
    /// upload bytes (via the platform media-processing seam) at publish
    /// time, so hitting Post can return immediately.
    public struct VideoAttachment: Identifiable, Sendable {
        public enum Source: Sendable, Equatable {
            /// A picked video file, unprocessed — transcoded when publishing.
            case video(URL)
            /// A recorded/imported audio take — rendered into a waveform
            /// video when publishing.
            case voiceMemo(URL)
        }

        public let id = UUID()
        public let source: Source
        public var altText: String = ""
        /// Clip length, when known at attach time — drives composer badges.
        public let duration: TimeInterval?
        /// Display dimensions hint, when known before processing (memo
        /// renders are a fixed canvas; picked videos read their track).
        public let aspectRatio: (width: Int, height: Int)?

        public var isVoiceMemo: Bool {
            if case .voiceMemo = source { return true }
            return false
        }

        /// The referenced file on disk.
        public var fileURL: URL {
            switch source {
            case .video(let url), .voiceMemo(let url): return url
            }
        }

        public init(
            source: Source,
            altText: String = "",
            duration: TimeInterval? = nil,
            aspectRatio: (width: Int, height: Int)? = nil
        ) {
            self.source = source
            self.altText = altText
            self.duration = duration
            self.aspectRatio = aspectRatio
        }
    }

    /// A GIF from the picker, posted as an external embed (the Bluesky
    /// convention) — mutually exclusive with images and video.
    public var attachedGIF: GIFItem? = nil

    public var characterCount: Int { text.count }
    public var isOverLimit: Bool { characterCount > 300 }
    public var remainingCharacters: Int { 300 - characterCount }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachedImages.isEmpty
            && attachedVideo == nil
            && attachedGIF == nil
    }

    public var canSubmit: Bool {
        // Media-only posts are valid (a GIF or voice memo needs no words).
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachedImages.isEmpty
            || attachedVideo != nil
            || attachedGIF != nil)
            && !isOverLimit
    }

    public init(id: UUID = UUID(), text: String = "") {
        self.id = id
        self.text = text
    }

    public func addImage(data: Data, fileName: String) {
        guard attachedImages.count < 4, attachedVideo == nil, attachedGIF == nil else { return }
        attachedImages.append(ImageAttachment(data: data, fileName: fileName))
        onMediaChanged?()
    }

    public func removeImage(id: UUID) {
        attachedImages.removeAll { $0.id == id }
        onMediaChanged?()
    }

    /// Sets the alt text on one attached image (no-op when the image was
    /// removed in the meantime — e.g. an async description arriving late).
    public func updateImageAltText(id: UUID, altText: String) {
        guard let index = attachedImages.firstIndex(where: { $0.id == id }) else { return }
        attachedImages[index].altText = altText
        onMediaChanged?()
    }

    /// Attaches a video reference, displacing any images (a post carries
    /// one or the other, never both). A displaced video reference's file
    /// is composer-owned — it goes with it.
    public func attachVideo(
        source: VideoAttachment.Source,
        duration: TimeInterval? = nil,
        aspectRatio: (width: Int, height: Int)? = nil
    ) {
        attachedImages.removeAll()
        attachedGIF = nil
        if let previous = attachedVideo {
            ComposerMediaFiles.delete(path: previous.fileURL.path)
        }
        attachedVideo = VideoAttachment(source: source, duration: duration, aspectRatio: aspectRatio)
        onMediaChanged?()
    }

    public func removeVideo() {
        if let previous = attachedVideo {
            ComposerMediaFiles.delete(path: previous.fileURL.path)
        }
        attachedVideo = nil
        onMediaChanged?()
    }

    /// Attaches a picked GIF, displacing other media (one embed per post).
    public func attachGIF(_ gif: GIFItem) {
        attachedImages.removeAll()
        if let previous = attachedVideo {
            ComposerMediaFiles.delete(path: previous.fileURL.path)
        }
        attachedVideo = nil
        attachedGIF = gif
        onMediaChanged?()
    }

    public func removeGIF() {
        attachedGIF = nil
        onMediaChanged?()
    }
}

// MARK: - Post Interaction Settings
/// Bluesky-style controls for who can reply to a new post (threadgate) and
/// whether it may be quoted (postgate). Mirrors the official app's sheet:
/// "Anyone" and "Nobody" are radio states; the three rule toggles combine.
public struct PostInteractionSettings: Equatable, Sendable {
    public var anyoneCanReply: Bool = true
    public var mentionedCanReply: Bool = false
    public var followingCanReply: Bool = false
    public var followersCanReply: Bool = false
    public var allowQuotePosts: Bool = true

    public init() {}

    /// Untouched settings need no gate records at all.
    public var isDefault: Bool { anyoneCanReply && allowQuotePosts }

    /// A threadgate record must accompany the post.
    public var needsThreadgate: Bool { !anyoneCanReply }

    /// The gate closes replies entirely (no rule selected).
    public var nobodyCanReply: Bool {
        !anyoneCanReply && !mentionedCanReply && !followingCanReply && !followersCanReply
    }
}

// MARK: - ComposerViewModel
@Observable
@MainActor
public final class ComposerViewModel {

    // MARK: Thread slots
    /// All posts in the thread being composed. Always has at least 1 slot.
    public var slots: [PostSlot] = [PostSlot()]

    // MARK: Context (set at init, doesn't change)
    public var replyTo: PostItem? = nil
    public var quotedPost: PostItem? = nil

    // MARK: Submission state
    public var isSubmitting: Bool = false
    public var submissionError: Error? = nil
    public var didSubmitSuccessfully: Bool = false

    // MARK: Interaction settings
    /// Who can reply / whether quoting is allowed — applied as threadgate
    /// and postgate records alongside the post at submit time.
    public var interactionSettings = PostInteractionSettings()

    // MARK: Translation (applies to the first post only)
    public var includeTranslationDisclosure: Bool = false
    public static let translationDisclosureSuffix = "\n\n[Translated with Apple Intelligence]"

    // MARK: User avatar — fetched once on appear
    public var currentUserAvatarURL: URL? = nil

    // MARK: Draft identity
    private let draftStore = DraftStore.shared
    private var draftID: UUID = UUID()

    /// True if any slot has content worth keeping — typed text or attached
    /// media (drafts persist media references now, so an image-only slot
    /// is a real draft).
    public var hasMeaningfulContent: Bool {
        slots.contains { !$0.isEmpty }
    }

    // MARK: Exit policy

    /// What should happen to the draft when the composer is closed without
    /// posting.
    public enum ExitDraftPolicy: Sendable {
        /// Nothing was typed — close silently and clear any stale autosave.
        case discardSilently
        /// A single post with content — ask the user whether to keep it.
        case promptToSave
        /// A multi-post thread — too much work to risk on a mis-tap: keep
        /// it without asking.
        case autoSave
    }

    /// Policy for the current slots. Text and media both count as content
    /// now that drafts persist media references.
    public var exitDraftPolicy: ExitDraftPolicy {
        Self.exitDraftPolicy(forContentfulSlots: slots.map { !$0.isEmpty })
    }

    /// Pure decision core, exposed for the unit tests.
    static func exitDraftPolicy(forContentfulSlots flags: [Bool]) -> ExitDraftPolicy {
        switch flags.filter({ $0 }).count {
        case 0:  return .discardSilently
        case 1:  return .promptToSave
        default: return .autoSave
        }
    }

    /// Text-only convenience kept for the existing unit tests.
    static func exitDraftPolicy(forSlotTexts texts: [String]) -> ExitDraftPolicy {
        exitDraftPolicy(forContentfulSlots: texts.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    // MARK: Validation
    /// True only when every slot can be posted and at least one slot exists.
    public var canSubmitThread: Bool {
        !isSubmitting
        && !slots.isEmpty
        && slots.allSatisfy { $0.canSubmit }
    }

    /// The character counter shown in the toolbar reflects the *focused* (last) slot.
    public var activeSlot: PostSlot { slots.last ?? slots[0] }

    private let service: ATProtoService

    // MARK: - Init

    public init(service: ATProtoService, replyTo: PostItem? = nil, quotedPost: PostItem? = nil) {
        self.service = service
        self.replyTo = replyTo
        self.quotedPost = quotedPost

        wireSlotCallbacks()
        restoreDraft()
    }

    // MARK: - Thread Management

    /// Appends a new empty post slot to the thread.
    public func addSlot() {
        let slot = PostSlot()
        slot.onTextChanged = { [weak self] in self?.scheduleDraftSave() }
        slot.onMediaChanged = { [weak self] in self?.scheduleDraftSave() }
        slots.append(slot)
        scheduleDraftSave()
    }

    /// Removes the slot with the given id. Never removes the last remaining slot.
    public func removeSlot(id: UUID) {
        guard slots.count > 1,
              let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        slots.remove(at: idx)
        scheduleDraftSave()
    }

    // MARK: - User Avatar

    /// Fetches the current user's avatar from their profile. Call once on composer appear.
    public func fetchCurrentUserAvatar() async {
        guard currentUserAvatarURL == nil,
              let kit = service.atProtoKit,
              let handle = service.currentHandle else { return }
        do {
            let profile = try await kit.getProfile(for: handle)
            currentUserAvatarURL = profile.avatarImageURL
        } catch {
            // Non-critical — composer still works, just no avatar shown
        }
    }

    // MARK: - Draft Auto-Save

    private var draftSaveTask: Task<Void, Never>? = nil

    /// Latched once the post has gone out: from that moment no code path —
    /// a late debounce, a dismissal policy, anything — may write a draft of
    /// content that was successfully published.
    private var draftsRetired = false

    private func wireSlotCallbacks() {
        for slot in slots {
            slot.onTextChanged = { [weak self] in self?.scheduleDraftSave() }
            slot.onMediaChanged = { [weak self] in self?.scheduleDraftSave() }
        }
    }

    /// Debounced save — fires 400 ms after the last keystroke.
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    public func saveDraft() {
        // Published content is not a draft.
        guard !draftsRetired else { return }
        // Never persist an empty draft — and if the user typed, autosave
        // fired, then they deleted everything, remove the stale copy too.
        guard hasMeaningfulContent else {
            draftStore.delete(id: draftID)
            return
        }

        // Image data files no longer referenced by the new snapshot
        // (removed attachments) get cleaned as part of the save.
        let previousImageIDs = Set(
            draftStore.drafts.first(where: { $0.id == draftID })?
                .posts.flatMap { $0.images.map(\.id) } ?? []
        )

        let draftPosts = slots.map { slot in
            DraftPost(
                id: slot.id,
                text: slot.text,
                attachedImageFileNames: slot.attachedImages.map { $0.fileName },
                images: slot.attachedImages.map { attachment in
                    ComposerMediaFiles.saveImage(attachment.data, id: attachment.id)
                    return DraftImageRef(
                        id: attachment.id,
                        fileName: attachment.fileName,
                        altText: attachment.altText
                    )
                },
                video: slot.attachedVideo.map { video in
                    DraftVideoRef(
                        kind: video.isVoiceMemo ? .voiceMemo : .video,
                        filePath: video.fileURL.path,
                        duration: video.duration,
                        aspectWidth: video.aspectRatio?.width,
                        aspectHeight: video.aspectRatio?.height,
                        altText: video.altText
                    )
                }
            )
        }

        let currentImageIDs = Set(draftPosts.flatMap { $0.images.map(\.id) })
        for stale in previousImageIDs.subtracting(currentImageIDs) {
            ComposerMediaFiles.deleteImage(id: stale)
        }

        let draft = ComposerDraft(
            id: draftID,
            posts: draftPosts,
            replyToURI: replyTo?.uri,
            quotedPostURI: quotedPost?.uri,
            modifiedAt: Date()
        )
        draftStore.save(draft)
    }

    /// Permanently deletes the draft (and its media files). Called after
    /// successful submission or user discard.
    ///
    /// `preservingVideoFileForPublishing`: the submit path discards the
    /// draft BEFORE PostPublisher processes the referenced video file —
    /// the publisher owns that file's cleanup.
    public func discardDraft(preservingVideoFileForPublishing: Bool = false) {
        draftSaveTask?.cancel()
        draftStore.delete(id: draftID, preservingVideoFile: preservingVideoFileForPublishing)
    }

    private func restoreDraft() {
        guard let saved = draftStore.latestDraft(
            replyToURI: replyTo?.uri,
            quotedPostURI: quotedPost?.uri
        ), !saved.isEmpty else { return }

        draftID = saved.id
        slots = Self.slots(restoring: saved)
        wireSlotCallbacks()
    }

    /// Switches the composer to an explicitly chosen draft (the composer's
    /// drafts button). Whatever is currently typed is saved under its own
    /// draft id first, so picking a draft never loses work.
    public func loadDraft(_ draft: ComposerDraft) {
        saveDraft()
        draftSaveTask?.cancel()
        draftID = draft.id
        slots = Self.slots(restoring: draft)
        if slots.isEmpty { slots = [PostSlot()] }
        wireSlotCallbacks()
    }

    /// Rebuilds composer slots from a draft, re-attaching persisted media.
    /// References whose backing files have vanished are skipped silently —
    /// the text always survives. Callbacks are wired AFTER mutation, so
    /// restoring never churns the autosave.
    private static func slots(restoring draft: ComposerDraft) -> [PostSlot] {
        draft.posts.map { draftPost in
            let slot = PostSlot(id: draftPost.id, text: draftPost.text)
            for imageRef in draftPost.images {
                guard let data = ComposerMediaFiles.loadImage(id: imageRef.id) else { continue }
                slot.addImage(data: data, fileName: imageRef.fileName)
                if let restored = slot.attachedImages.last, !imageRef.altText.isEmpty {
                    slot.updateImageAltText(id: restored.id, altText: imageRef.altText)
                }
            }
            if let videoRef = draftPost.video,
               FileManager.default.fileExists(atPath: videoRef.filePath) {
                let url = URL(fileURLWithPath: videoRef.filePath)
                let ratio: (width: Int, height: Int)? =
                    (videoRef.aspectWidth != nil && videoRef.aspectHeight != nil)
                    ? (videoRef.aspectWidth!, videoRef.aspectHeight!)
                    : nil
                slot.attachVideo(
                    source: videoRef.kind == .voiceMemo ? .voiceMemo(url) : .video(url),
                    duration: videoRef.duration,
                    aspectRatio: ratio
                )
                if !videoRef.altText.isEmpty {
                    slot.attachedVideo?.altText = videoRef.altText
                }
            }
            return slot
        }
    }

    // MARK: - Submit

    /// Value snapshot of the thread for PostPublisher — taken at Post time
    /// so publishing works from a copy while the composer goes away.
    public func makePayload() -> PostThreadPayload {
        PostThreadPayload(
            slots: slots.map { slot in
                PostThreadPayload.Slot(
                    text: slot.text,
                    images: slot.attachedImages.map {
                        PostThreadPayload.Slot.Image(
                            data: $0.data,
                            fileName: $0.fileName,
                            altText: $0.altText
                        )
                    },
                    video: slot.attachedVideo,
                    gif: slot.attachedGIF
                )
            },
            replyTo: replyTo,
            quotedPost: quotedPost,
            interactionSettings: interactionSettings,
            includeTranslationDisclosure: includeTranslationDisclosure
        )
    }

    /// Inline publish (macOS, and any caller that wants to await): the
    /// composer stays up with its spinner until the thread is out, and
    /// errors surface in the sheet.
    public func submit() async {
        guard canSubmitThread else { return }

        isSubmitting = true
        submissionError = nil

        do {
            try await PostPublisher.shared.publishNow(makePayload(), service: service)

            // Retire drafting BEFORE deleting: any in-flight debounce or
            // later dismissal policy becomes a no-op, so a sent post can
            // never leave a draft copy behind.
            draftsRetired = true
            discardDraft()
            didSubmitSuccessfully = true
        } catch {
            submissionError = error
        }

        isSubmitting = false
    }

    /// Background publish (iOS): hands the snapshot to PostPublisher and
    /// returns immediately so the composer can dismiss. Progress shows in
    /// the status pill and the Live Activity; a failure saves the text
    /// back to Drafts (the publisher owns that — the composer is gone).
    public func submitInBackground() {
        guard canSubmitThread else { return }

        let payload = makePayload()
        // The content now belongs to the publisher; the composer's own
        // draft would otherwise resurrect on dismissal. The video file
        // stays — the publisher processes and then cleans it.
        draftsRetired = true
        discardDraft(preservingVideoFileForPublishing: true)

        PostPublisher.shared.enqueue(payload, service: service)
        didSubmitSuccessfully = true
    }
}
