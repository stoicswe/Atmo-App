import Foundation
import ATProtoKit
import SwiftUI
import Observation

// MARK: - PostSlot
// Represents one post in a thread being composed. Each slot has its own
// text, image attachments, and character count — and is rendered as a
// separate row in the thread composer UI.
@Observable
@MainActor
final class PostSlot: Identifiable {
    let id: UUID
    var text: String = "" {
        didSet { onTextChanged?() }
    }
    var attachedImages: [ImageAttachment] = []

    /// Fired whenever text changes — wired by ComposerViewModel for draft auto-save.
    var onTextChanged: (() -> Void)? = nil

    struct ImageAttachment: Identifiable {
        let id = UUID()
        let data: Data
        let fileName: String
        var altText: String = ""
    }

    var characterCount: Int { text.count }
    var isOverLimit: Bool { characterCount > 300 }
    var remainingCharacters: Int { 300 - characterCount }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedImages.isEmpty
    }

    var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isOverLimit
    }

    init(id: UUID = UUID(), text: String = "") {
        self.id = id
        self.text = text
    }

    func addImage(data: Data, fileName: String) {
        guard attachedImages.count < 4 else { return }
        attachedImages.append(ImageAttachment(data: data, fileName: fileName))
    }

    func removeImage(id: UUID) {
        attachedImages.removeAll { $0.id == id }
    }
}

// MARK: - ComposerViewModel
@Observable
@MainActor
final class ComposerViewModel {

    // MARK: Thread slots
    /// All posts in the thread being composed. Always has at least 1 slot.
    var slots: [PostSlot] = [PostSlot()]

    // MARK: Context (set at init, doesn't change)
    var replyTo: PostItem? = nil
    var quotedPost: PostItem? = nil

    // MARK: Submission state
    var isSubmitting: Bool = false
    var submissionError: Error? = nil
    var didSubmitSuccessfully: Bool = false

    // MARK: Translation (applies to the first post only)
    var includeTranslationDisclosure: Bool = false
    static let translationDisclosureSuffix = "\n\n[Translated with Apple Intelligence]"

    // MARK: User avatar — fetched once on appear
    var currentUserAvatarURL: URL? = nil

    // MARK: Draft identity
    private let draftStore = DraftStore.shared
    private var draftID: UUID = UUID()

    /// True if any slot has non-whitespace content — used to decide whether
    /// to show the "discard draft?" prompt when the user cancels.
    var hasMeaningfulContent: Bool {
        slots.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: Validation
    /// True only when every slot can be posted and at least one slot exists.
    var canSubmitThread: Bool {
        !isSubmitting
        && !slots.isEmpty
        && slots.allSatisfy { $0.canSubmit }
    }

    /// The character counter shown in the toolbar reflects the *focused* (last) slot.
    var activeSlot: PostSlot { slots.last ?? slots[0] }

    private let service: ATProtoService

    // MARK: - Init

    init(service: ATProtoService, replyTo: PostItem? = nil, quotedPost: PostItem? = nil) {
        self.service = service
        self.replyTo = replyTo
        self.quotedPost = quotedPost

        wireSlotCallbacks()
        restoreDraft()
    }

    // MARK: - Thread Management

    /// Appends a new empty post slot to the thread.
    func addSlot() {
        let slot = PostSlot()
        slot.onTextChanged = { [weak self] in self?.scheduleDraftSave() }
        slots.append(slot)
        scheduleDraftSave()
    }

    /// Removes the slot with the given id. Never removes the last remaining slot.
    func removeSlot(id: UUID) {
        guard slots.count > 1,
              let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        slots.remove(at: idx)
        scheduleDraftSave()
    }

    // MARK: - User Avatar

    /// Fetches the current user's avatar from their profile. Call once on composer appear.
    func fetchCurrentUserAvatar() async {
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

    func saveDraft() {
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
    func discardDraft() {
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

    // MARK: - Submit

    func submit() async {
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

                // Embed: quote only on first post; images on any post
                let embed: ATProtoBluesky.EmbedIdentifier?
                if index == 0, let quoted = quotedPost {
                    let quoteRef = ComAtprotoLexicon.Repository.StrongReference(
                        recordURI: quoted.uri,
                        cidHash: quoted.cid
                    )
                    embed = .record(strongReference: quoteRef)
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
                }
            }

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
