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

    public struct VideoAttachment: Identifiable {
        public let id = UUID()
        public let data: Data
        public let fileName: String
        public var altText: String = ""
        /// Display dimensions of the (transcoded) video, when known — sent
        /// with the embed so clients reserve the right box before playback.
        public let aspectRatio: (width: Int, height: Int)?

        public init(data: Data, fileName: String, altText: String = "", aspectRatio: (width: Int, height: Int)? = nil) {
            self.data = data
            self.fileName = fileName
            self.altText = altText
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
    }

    public func removeImage(id: UUID) {
        attachedImages.removeAll { $0.id == id }
    }

    /// Sets the alt text on one attached image (no-op when the image was
    /// removed in the meantime — e.g. an async description arriving late).
    public func updateImageAltText(id: UUID, altText: String) {
        guard let index = attachedImages.firstIndex(where: { $0.id == id }) else { return }
        attachedImages[index].altText = altText
    }

    /// Attaches a video, displacing any images (a post carries one or the
    /// other, never both).
    public func attachVideo(data: Data, fileName: String, aspectRatio: (width: Int, height: Int)? = nil) {
        attachedImages.removeAll()
        attachedGIF = nil
        attachedVideo = VideoAttachment(data: data, fileName: fileName, aspectRatio: aspectRatio)
    }

    public func removeVideo() {
        attachedVideo = nil
    }

    /// Attaches a picked GIF, displacing other media (one embed per post).
    public func attachGIF(_ gif: GIFItem) {
        attachedImages.removeAll()
        attachedVideo = nil
        attachedGIF = gif
    }

    public func removeGIF() {
        attachedGIF = nil
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

    /// True if any slot has non-whitespace content — used to decide whether
    /// to show the "discard draft?" prompt when the user cancels.
    public var hasMeaningfulContent: Bool {
        slots.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

    /// Policy for the current slots. Only typed text counts as content —
    /// drafts persist image *file names*, not the images, so an image-only
    /// slot would restore to nothing worth keeping.
    public var exitDraftPolicy: ExitDraftPolicy {
        Self.exitDraftPolicy(forSlotTexts: slots.map(\.text))
    }

    /// Pure decision core, exposed for the unit tests.
    static func exitDraftPolicy(forSlotTexts texts: [String]) -> ExitDraftPolicy {
        let contentful = texts.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        switch contentful {
        case 0:  return .discardSilently
        case 1:  return .promptToSave
        default: return .autoSave
        }
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
        let draftPosts = slots.map { slot in
            DraftPost(
                id: slot.id,
                text: slot.text,
                attachedImageFileNames: slot.attachedImages.map { $0.fileName }
            )
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

    /// Permanently deletes the draft. Called after successful submission or user discard.
    public func discardDraft() {
        draftSaveTask?.cancel()
        draftStore.delete(id: draftID)
    }

    private func restoreDraft() {
        guard let saved = draftStore.latestDraft(
            replyToURI: replyTo?.uri,
            quotedPostURI: quotedPost?.uri
        ), !saved.isEmpty else { return }

        draftID = saved.id
        slots = saved.posts.map { draftPost in
            PostSlot(id: draftPost.id, text: draftPost.text)
        }
        wireSlotCallbacks()
    }

    /// Switches the composer to an explicitly chosen draft (the composer's
    /// drafts button). Whatever is currently typed is saved under its own
    /// draft id first, so picking a draft never loses work.
    public func loadDraft(_ draft: ComposerDraft) {
        saveDraft()
        draftSaveTask?.cancel()
        draftID = draft.id
        slots = draft.posts.map { PostSlot(id: $0.id, text: $0.text) }
        if slots.isEmpty { slots = [PostSlot()] }
        wireSlotCallbacks()
    }

    // MARK: - Submit

    public func submit() async {
        guard canSubmitThread,
              let bluesky = service.atProtoBluesky,
              let kit = service.atProtoKit else { return }

        isSubmitting = true
        submissionError = nil

        do {
            // Build the reply reference for the first post in the thread
            var firstReplyRef: AppBskyLexicon.Feed.PostRecord.ReplyReference? = nil
            if let replyPost = replyTo,
               let session = try? await kit.getUserSession() {
                let strongRef = ComAtprotoLexicon.Repository.StrongReference(
                    recordURI: replyPost.uri,
                    cidHash: replyPost.cid
                )
                firstReplyRef = try await ATProtoTools().createReplyReference(
                    from: strongRef,
                    session: session
                )
            }

            // Post each slot in sequence. After the first, each post replies to the
            // previous one to form a proper AT Protocol thread.
            var previousRef: ComAtprotoLexicon.Repository.StrongReference? = nil
            var threadRootRef: ComAtprotoLexicon.Repository.StrongReference? = nil

            for (index, slot) in slots.enumerated() {
                // Images for this slot
                let imageQueries: [ATProtoTools.ImageQuery] = slot.attachedImages.map {
                    ATProtoTools.ImageQuery(
                        imageData: $0.data,
                        fileName: $0.fileName,
                        altText: $0.altText.isEmpty ? nil : $0.altText,
                        aspectRatio: nil
                    )
                }

                // Embed: quote only on first post; a video or images on any
                // post (mutually exclusive — PostSlot enforces it).
                let embed: ATProtoBluesky.EmbedIdentifier?
                if index == 0, let quoted = quotedPost {
                    let quoteRef = ComAtprotoLexicon.Repository.StrongReference(
                        recordURI: quoted.uri,
                        cidHash: quoted.cid
                    )
                    embed = .record(strongReference: quoteRef)
                } else if let video = slot.attachedVideo {
                    embed = .video(
                        video: video.data,
                        captions: nil,
                        altText: video.altText.isEmpty ? nil : video.altText,
                        aspectoRatio: video.aspectRatio.map {
                            AppBskyLexicon.Embed.AspectRatioDefinition(width: $0.width, height: $0.height)
                        }
                    )
                } else if let gif = slot.attachedGIF {
                    // GIFs travel as external embeds pointing at the media
                    // URL with ww/hh dimensions — the Bluesky convention.
                    embed = .external(
                        url: gif.embedURL,
                        title: gif.title,
                        description: "Animated GIF",
                        thumbnailURL: gif.previewURL
                    )
                } else if !imageQueries.isEmpty {
                    embed = .images(images: imageQueries)
                } else {
                    embed = nil
                }

                // Translation disclosure only on the first post
                let postText = (index == 0 && includeTranslationDisclosure)
                    ? slot.text + ComposerViewModel.translationDisclosureSuffix
                    : slot.text

                // Reply reference: first post uses the incoming replyRef;
                // subsequent posts reply to the previous slot's result.
                let replyRef: AppBskyLexicon.Feed.PostRecord.ReplyReference?
                if index == 0 {
                    replyRef = firstReplyRef
                } else if let prev = previousRef, let root = threadRootRef {
                    replyRef = AppBskyLexicon.Feed.PostRecord.ReplyReference(
                        root: root,
                        parent: prev
                    )
                } else {
                    replyRef = nil
                }

                let result = try await bluesky.createPostRecord(
                    text: postText,
                    locales: [Locale.current],
                    replyTo: replyRef,
                    embed: embed
                )

                let thisRef = ComAtprotoLexicon.Repository.StrongReference(
                    recordURI: result.recordURI,
                    cidHash: result.recordCID
                )
                previousRef = thisRef

                // The root of this thread is:
                //   • the replyRef's root (if replying to an existing thread), OR
                //   • this very first post (if starting a new thread)
                if index == 0 {
                    threadRootRef = firstReplyRef?.root ?? thisRef

                    // ── Interaction gates ──
                    // Applied best-effort (try?): the post already exists at
                    // this point, and failing a gate must not surface an
                    // error that would tempt a duplicate resubmission.
                    //
                    // Threadgate (who can reply) — only meaningful on a NEW
                    // thread's root; a reply can't gate someone else's thread.
                    if replyTo == nil, interactionSettings.needsThreadgate {
                        var rules: [ATProtoBluesky.ThreadgateAllowRule] = []
                        if interactionSettings.mentionedCanReply { rules.append(.allowMentions) }
                        if interactionSettings.followingCanReply { rules.append(.allowFollowing) }
                        if interactionSettings.followersCanReply { rules.append(.allowFollowers) }
                        // Empty rules == nobody can reply.
                        _ = try? await bluesky.createThreadgateRecord(
                            postURI: thisRef.recordURI,
                            replyControls: rules
                        )
                    }

                    // Postgate (quote control) — applies to any post.
                    if !interactionSettings.allowQuotePosts {
                        _ = try? await bluesky.createPostgateRecord(
                            postURI: thisRef.recordURI,
                            embeddingRules: [.disable]
                        )
                    }
                }
            }

            // Retire drafting BEFORE deleting: any in-flight debounce or
            // later dismissal policy becomes a no-op, so a sent post can
            // never leave a draft copy behind.
            draftsRetired = true
            discardDraft()
            didSubmitSuccessfully = true

            // Notify observers (e.g. ProfileViewModel) that a new post was submitted
            // so they can refresh their feed without requiring a full app reload.
            NotificationCenter.default.post(name: .atmoDidSubmitPost, object: nil)

        } catch {
            submissionError = error
        }

        isSubmitting = false
    }
}
