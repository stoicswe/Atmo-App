import Adwaita
import Foundation
import AtmoCore

extension MainView {

    /// Composer dialog on the shared ComposerViewModel: multi-post
    /// threads (slots), image attachments with alt text, reply and quote
    /// context, ghost posts, and draft autosave — facets, media fitting,
    /// and publishing come from core (PostPublisher).

    // MARK: - Snapshots

    struct ComposeSlotSnapshot: Identifiable, Equatable {
        struct Image: Identifiable, Equatable {
            let id: UUID
            let data: Data
            let altText: String
        }
        let id: UUID
        let index: Int
        let text: String
        let remaining: Int
        let images: [Image]
    }

    struct ComposeSnapshot {
        var slots: [ComposeSlotSnapshot] = []
        var replyToName: String?
        var quoted: (author: String, text: String)?
        var canSubmit = false
        var isSubmitting = false
        var isGhost = false
        var hasDraftContent = false
    }

    var composeSnapshot: ComposeSnapshot {
        _ = tick
        return onMain {
            guard let composer = AppSession.shared.composer else { return ComposeSnapshot() }
            var snapshot = ComposeSnapshot()
            snapshot.slots = composer.slots.enumerated().map { index, slot in
                ComposeSlotSnapshot(
                    id: slot.id,
                    index: index,
                    text: slot.text,
                    remaining: slot.remainingCharacters,
                    images: slot.attachedImages.map { .init(id: $0.id, data: $0.data, altText: $0.altText) }
                )
            }
            snapshot.replyToName = composer.replyTo.map { $0.authorDisplayName ?? "@\($0.authorHandle)" }
            snapshot.quoted = composer.quotedPost.map {
                ($0.authorDisplayName ?? "@\($0.authorHandle)", $0.displayText)
            }
            snapshot.canSubmit = composer.canSubmitThread
            snapshot.isSubmitting = composer.isSubmitting
            snapshot.isGhost = composer.isGhost
            snapshot.hasDraftContent = composer.hasMeaningfulContent
            return snapshot
        }
    }

    var composeTitle: String {
        let snapshot = composeSnapshot
        if snapshot.replyToName != nil { return "Reply" }
        if snapshot.quoted != nil { return "Quote Post" }
        return snapshot.slots.count > 1 ? "New Thread" : "New Post"
    }

    /// Closing the dialog (Cancel, Escape, or the X) finalizes the draft.
    var composeVisibleBinding: Binding<Bool> {
        Binding(
            get: { composeVisible },
            set: { visible in
                composeVisible = visible
                if !visible { finishComposer() }
            }
        )
    }

    // MARK: - Opening

    func openComposer(replyTo: PostItem? = nil, quoting: PostItem? = nil, source: RowActions? = nil, draft: ComposerDraft? = nil) {
        onMain {
            let composer = ComposerViewModel(service: AppSession.shared.service, replyTo: replyTo, quotedPost: quoting)
            if let draft {
                composer.loadDraft(draft)
            }
            AppSession.shared.composer = composer
        }
        composeQuoteSource = source
        composeTargetSlot = 0
        composeVisible = true
        tick += 1
    }

    /// Saves or discards on close, mirroring the Apple exit policy — with
    /// one GNOME deviation: a single-post draft is saved without asking.
    func finishComposer() {
        let saved = onMain { () -> Bool in
            guard let composer = AppSession.shared.composer else { return false }
            defer { AppSession.shared.composer = nil }
            if composer.didSubmitSuccessfully { return false }
            switch composer.exitDraftPolicy {
            case .discardSilently:
                composer.discardDraft()
                return false
            case .promptToSave, .autoSave:
                composer.saveDraft()
                return true
            }
        }
        if saved { showToast("Draft saved") }
        tick += 1
    }

    // MARK: - Content

    @ViewBuilder var composeContent: Body {
        let snapshot = composeSnapshot
        VStack(spacing: 8) {
            if let replyToName = snapshot.replyToName {
                Text("↩ Replying to \(replyToName)")
                    .style("dim-label")
                    .halign(.start)
                    .padding(8, .horizontal)
            }
            if let quoted = snapshot.quoted {
                VStack(spacing: 2) {
                    Text(quoted.author)
                        .style("caption-heading")
                        .halign(.start)
                    Text(quoted.text)
                        .wrap()
                        .lines(3)
                        .ellipsize()
                        .style("dim-label")
                        .halign(.start)
                }
                .padding(8)
                .style("card")
                .padding(8, .horizontal)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(snapshot.slots, id: \.id) { slot in
                        composeSlot(slot, total: snapshot.slots.count)
                    }
                }
                .padding(8, .horizontal)
            }
            .vexpand()
            composeToolbar(snapshot)
        }
        .fileImporter(
            open: $composeImagePicker,
            filters: [.extensions(["png", "jpg", "jpeg", "webp", "gif", "bmp", "tiff"], name: "Images")],
            title: "Attach Image",
            onOpen: { url in attachImage(from: url) }
        )
    }

    @ViewBuilder func composeSlot(_ slot: ComposeSlotSnapshot, total: Int) -> Body {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if total > 1 {
                    Text("Post \(slot.index + 1) of \(total)")
                        .style("caption")
                        .style("dim-label")
                        .halign(.start)
                        .hexpand()
                    Button(icon: .custom(name: "user-trash-symbolic")) { removeSlot(slot.id) }
                        .flat()
                        .tooltip("Remove from thread")
                }
            }
            TextEditor(text: slotTextBinding(slot.index))
                .innerPadding(8)
                .frame(minHeight: total > 1 ? 90 : 160)
                .style("card")
            if !slot.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(slot.images, id: \.id) { image in
                        VStack(spacing: 4) {
                            Picture(data: image.data)
                                .canShrink()
                                .contentFit(.scaleDown)
                                .frame(maxHeight: 110)
                            Entry("Alt text", text: altTextBinding(slotIndex: slot.index, imageID: image.id))
                            Button(icon: .custom(name: "edit-delete-symbolic")) {
                                removeImage(slotIndex: slot.index, imageID: image.id)
                            }
                            .flat()
                            .tooltip("Remove image")
                        }
                        .hexpand()
                    }
                }
            }
            HStack(spacing: 6) {
                Button(icon: .custom(name: "image-x-generic-symbolic")) {
                    composeTargetSlot = slot.index
                    composeImagePicker.signal()
                }
                .flat()
                .tooltip("Attach image (up to 4)")
                .insensitive(slot.images.count >= 4)
                Text("\(slot.remaining)")
                    .style(slot.remaining < 0 ? "error" : "dim-label")
                    .style("caption")
                    .hexpand()
                    .halign(.end)
            }
        }
    }

    @ViewBuilder func composeToolbar(_ snapshot: ComposeSnapshot) -> Body {
        HStack(spacing: 8) {
            Button("Add to Thread", icon: .custom(name: "list-add-symbolic")) { addSlot() }
                .flat()
                .insensitive(snapshot.replyToName != nil && snapshot.slots.count >= 1 && false)
            if ghostsEnabled && snapshot.replyToName == nil {
                Toggle("Ghost (24 h)", isOn: ghostBinding)
                    .tooltip("Takes the post down after 24 hours")
            }
            Text("")
                .hexpand()
            Button("Cancel") { composeVisibleBinding.wrappedValue = false }
            Button(snapshot.isSubmitting ? "Posting…" : (snapshot.slots.count > 1 ? "Post All" : "Post")) { submitPost() }
                .style("suggested-action")
                .insensitive(!snapshot.canSubmit || snapshot.isSubmitting)
        }
        .padding(8)
    }

    // MARK: - Bindings into the model

    func slotTextBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { onMain { AppSession.shared.composer?.slots[safe: index]?.text ?? "" } },
            set: { value in
                onMain {
                    guard let composer = AppSession.shared.composer, composer.slots.indices.contains(index),
                          composer.slots[index].text != value else { return }
                    composer.slots[index].text = value
                }
                tick += 1
            }
        )
    }

    func altTextBinding(slotIndex: Int, imageID: UUID) -> Binding<String> {
        Binding(
            get: {
                onMain {
                    AppSession.shared.composer?.slots[safe: slotIndex]?.attachedImages.first { $0.id == imageID }?.altText ?? ""
                }
            },
            set: { value in
                onMain {
                    guard let composer = AppSession.shared.composer, composer.slots.indices.contains(slotIndex) else { return }
                    composer.slots[slotIndex].updateImageAltText(id: imageID, altText: value)
                }
            }
        )
    }

    var ghostBinding: Binding<Bool> {
        Binding(
            get: { onMain { AppSession.shared.composer?.isGhost ?? false } },
            set: { value in
                onMain { AppSession.shared.composer?.isGhost = value }
                tick += 1
            }
        )
    }

    // MARK: - Actions

    func addSlot() {
        onMain { AppSession.shared.composer?.addSlot() }
        tick += 1
    }

    func removeSlot(_ id: UUID) {
        onMain { AppSession.shared.composer?.removeSlot(id: id) }
        tick += 1
    }

    func attachImage(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            presentError("That file couldn't be read.")
            return
        }
        let index = composeTargetSlot
        onMain {
            guard let composer = AppSession.shared.composer, composer.slots.indices.contains(index) else { return }
            composer.slots[index].addImage(data: data, fileName: url.lastPathComponent)
        }
        tick += 1
    }

    func removeImage(slotIndex: Int, imageID: UUID) {
        onMain {
            guard let composer = AppSession.shared.composer, composer.slots.indices.contains(slotIndex) else { return }
            composer.slots[slotIndex].removeImage(id: imageID)
        }
        tick += 1
    }

    func submitPost() {
        let source = composeQuoteSource
        runCore {
            guard let composer = AppSession.shared.composer else { return }
            let replyTo = composer.replyTo
            let quoted = composer.quotedPost
            await composer.submit()
            if composer.didSubmitSuccessfully {
                composeVisible = false
                AppSession.shared.composer = nil
                if let quoted, let source, let store = interactions(for: source) {
                    store.markAsQuoted(post: quoted)
                }
                if let replyTo {
                    // A reply from a thread page: refresh that thread so
                    // the new post shows in place.
                    let root = replyTo.replyRootURI ?? replyTo.uri
                    for uri in [replyTo.uri, root] {
                        let session = AppSession.shared.threadSession(for: uri)
                        if session.thread.rootPost != nil {
                            await session.thread.load()
                            session.interactions.seedPosts(session.thread.allPosts)
                        }
                    }
                }
                _ = await AppSession.shared.timeline?.checkForNewPosts()
                showToast(composer.isGhost ? "Ghost posted" : "Posted")
            } else {
                presentError("The post couldn't be sent. Check your connection and try again.")
            }
        }
    }
}
