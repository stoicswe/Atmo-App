import SwiftUI
import AtmoCore
import PhotosUI
import Translation

// MARK: - ComposerView
// Threads-style composer sheet for a new post, a reply, or a quote post —
// carrying only the features Bluesky supports: text (300 chars/post),
// up to 4 images per post with alt text, multi-post threads, reply/quote
// context, and drafts.
//
// Layout (mirroring the Threads composer):
//   • Header: Cancel · centered title · "…" menu (Save/Discard Draft)
//   • Each slot: avatar column with a connector line, bold username,
//     the text field, a media icon row, and image thumbnails
//   • A dimmed "Add to thread" ghost row (enabled once the last slot
//     has content)
//   • Bottom bar: "Post Options" · character ring · Post pill
//
// Draft behaviour (driven by ComposerViewModel.exitDraftPolicy):
//   • Text is auto-saved 400 ms after each keystroke via ComposerViewModel
//     (the VM refuses to persist empty drafts and clears stale autosaves).
//   • Exiting with NO typed content closes silently — no draft is kept.
//   • Exiting a SINGLE post with content prompts "Save / Discard / Keep
//     Editing" (interactive swipe-dismiss is blocked in this state so the
//     prompt can't be bypassed accidentally).
//   • Exiting a MULTI-POST thread auto-saves without asking — too much
//     work to risk on a mis-tap — and shows the "Draft saved" toast.
//   • Submitting successfully auto-discards the draft and dismisses the sheet.
struct ComposerView: View {
    var replyTo: PostItem? = nil
    /// When set, the composer will embed this post as a quote post.
    var quotedPost: PostItem? = nil
    /// Optional callback fired on the main actor immediately after a successful submission,
    /// before the sheet is dismissed. Used by callers that need to react to success
    /// (e.g. PostActionsView marking a post as quoted for optimistic UI).
    var onSuccess: (() -> Void)? = nil
    /// Fired when the sheet is swiped away with unsaved content — the draft is
    /// auto-saved before the callback fires. Use this to show a "Draft saved" toast.
    var onDraftSaved: (() -> Void)? = nil

    @Environment(ATProtoService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @Environment(\.draftSaved) private var draftSavedAction
    @State private var viewModel: ComposerViewModel?

    // Focus is owned here so we can auto-focus the first slot on appear.
    @FocusState private var focusedSlotID: UUID?

    // Cancel confirmation
    @State private var showDiscardAlert: Bool = false

    // Tracks whether the user explicitly chose what to do (Post sent, Discard chosen,
    // or empty-cancel). If false when onDisappear fires, the sheet was dismissed
    // externally — swipe on iOS, click-outside or native Cancel on macOS — and we
    // should auto-save the draft.
    @State private var dismissedExplicitly: Bool = false

    // Translation state for the reply-to post
    @State private var showReplyTranslation: Bool = false
    @State private var didUseTranslation: Bool = false

    /// Header title, Threads-style: reflects what is being composed right now.
    private var composerTitle: String {
        if quotedPost != nil { return "Quote Post" }
        if replyTo != nil { return "Reply" }
        return (viewModel?.slots.count ?? 1) > 1 ? "New Thread" : "New Post"
    }

    var body: some View {
        NavigationStack {
            // The system sheet already provides the correct Liquid Glass
            // era background — no custom material layer on top of it.
            ZStack {
                if let vm = viewModel {
                    ScrollView {
                        VStack(spacing: 0) {

                            // ── Reply context header ──
                            if let replyPost = vm.replyTo {
                                replyHeader(post: replyPost)
                                Divider().overlay(AtmoColors.glassDivider)
                            }

                            // ── Translation suggestion banner ──
                            if let replyPost = vm.replyTo,
                               TranslationHelper.needsTranslation(replyPost.text) {
                                replyTranslationBanner(post: replyPost, vm: vm)
                            }

                            // ── Thread slots ──
                            ForEach(Array(vm.slots.enumerated()), id: \.element.id) { index, slot in
                                SlotComposerRow(
                                    slot: slot,
                                    avatarURL: vm.currentUserAvatarURL,
                                    handle: service.currentHandle,
                                    isFirst: index == 0,
                                    isLast: index == vm.slots.count - 1,
                                    canRemove: vm.slots.count > 1,
                                    showQuotedPost: index == 0 ? vm.quotedPost : nil,
                                    onRemove: { vm.removeSlot(id: slot.id) }
                                )
                                .focused($focusedSlotID, equals: slot.id)

                                // "Add to thread" ghost row after the last slot.
                                if index == vm.slots.count - 1 {
                                    addToThreadRow(vm: vm)
                                }
                            }

                            // Error banner
                            if let error = vm.submissionError {
                                ErrorBannerView(message: error.localizedDescription)
                                    .padding(AtmoTheme.Spacing.lg)
                            }

                            // Bottom padding so the toolbar doesn't overlap content
                            Spacer(minLength: 80)
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        ComposerToolbar(viewModel: vm, showTranslationDisclosureOption: didUseTranslation)
                    }
                }
            }
            .navigationTitle(composerTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { handleCancel() }
                }
                // Threads-style "…" menu: explicit draft actions live here.
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            dismissedExplicitly = true
                            viewModel?.saveDraft()
                            onDraftSaved?()
                            draftSavedAction()
                            dismiss()
                        } label: {
                            Label("Save Draft", systemImage: "square.and.arrow.down")
                        }
                        .disabled(viewModel?.hasMeaningfulContent != true)

                        Button(role: .destructive) {
                            dismissedExplicitly = true
                            viewModel?.discardDraft()
                            dismiss()
                        } label: {
                            Label("Discard Draft", systemImage: "trash")
                        }
                        .disabled(viewModel?.hasMeaningfulContent != true)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog(
                "What would you like to do?",
                isPresented: $showDiscardAlert,
                titleVisibility: .visible
            ) {
                Button("Save Draft") {
                    // Explicit save — flush immediately, show toast, then close.
                    dismissedExplicitly = true
                    viewModel?.saveDraft()
                    onDraftSaved?()
                    draftSavedAction()
                    dismiss()
                }
                Button("Discard Draft", role: .destructive) {
                    dismissedExplicitly = true
                    viewModel?.discardDraft()
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Save your draft to continue editing it later, or discard it permanently.")
            }
            .task {
                if viewModel == nil {
                    viewModel = ComposerViewModel(
                        service: service,
                        replyTo: replyTo,
                        quotedPost: quotedPost
                    )
                }
                // Auto-focus the first slot
                if let firstID = viewModel?.slots.first?.id {
                    focusedSlotID = firstID
                }
            }
            .onChange(of: viewModel?.didSubmitSuccessfully) { _, success in
                if success == true {
                    dismissedExplicitly = true
                    onSuccess?()
                    dismiss()
                }
            }
            // Fetch avatar once on appear
            .task {
                await viewModel?.fetchCurrentUserAvatar()
            }
            // Single contentful post: the exit decision belongs to the user,
            // so the swipe can't bypass the Save/Discard prompt — Cancel is
            // the way out. Empty and multi-post states dismiss freely.
            .interactiveDismissDisabled(viewModel?.exitDraftPolicy == .promptToSave)
            // External dismissal (swipe on iOS, click-outside or native Cancel
            // on macOS) never went through handleCancel — apply the exit
            // policy here. promptToSave can still land here on macOS paths
            // where no prompt is possible; saving is the safe default there.
            .onDisappear {
                guard let vm = viewModel, !dismissedExplicitly else { return }
                switch vm.exitDraftPolicy {
                case .discardSilently:
                    // Clears any stale autosave from text that was deleted.
                    vm.discardDraft()
                case .promptToSave, .autoSave:
                    // Flush the debounced auto-save immediately and notify
                    // both the direct callback (if any) and the environment action.
                    vm.saveDraft()
                    onDraftSaved?()
                    draftSavedAction()
                }
            }
            // System translation sheet for the reply-to post
            .translationPresentation(
                isPresented: $showReplyTranslation,
                text: replyTo?.text ?? ""
            )
        }
    }

    // MARK: - Cancel handling

    private func handleCancel() {
        guard let vm = viewModel else {
            dismissedExplicitly = true
            dismiss()
            return
        }
        switch vm.exitDraftPolicy {
        case .discardSilently:
            // Nothing typed — close cleanly without a draft.
            dismissedExplicitly = true
            vm.discardDraft()
            dismiss()
        case .promptToSave:
            // Single post: the user chooses Save / Discard / Keep Editing.
            // dismissedExplicitly is set inside the chosen button's action.
            showDiscardAlert = true
        case .autoSave:
            // Multi-post thread: keep it without asking, with the toast as
            // the receipt.
            dismissedExplicitly = true
            vm.saveDraft()
            onDraftSaved?()
            draftSavedAction()
            dismiss()
        }
    }

    // MARK: - Add to Thread Row
    // Threads-style ghost row: a dimmed mini avatar aligned under the
    // avatar column and a muted label. Disabled until the last slot has
    // content, exactly like Threads.

    private func addToThreadRow(vm: ComposerViewModel) -> some View {
        let enabled = !vm.activeSlot.isEmpty
        return Button {
            vm.addSlot()
            // Focus the newly added slot after SwiftUI updates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedSlotID = vm.slots.last?.id
            }
        } label: {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                // Mini avatar aligned with the avatar column
                AvatarView(url: vm.currentUserAvatarURL, size: AtmoTheme.AvatarSize.medium * 0.55)
                    .opacity(0.45)
                    .padding(.leading,
                        AtmoTheme.Feed.horizontalPadding +
                        (AtmoTheme.AvatarSize.medium - AtmoTheme.AvatarSize.medium * 0.55) / 2
                    )

                Text("Add to thread")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.vertical, AtmoTheme.Spacing.sm)
        .animation(.easeInOut(duration: 0.15), value: enabled)
    }

    // MARK: - Reply Header

    private func replyHeader(post: PostItem) -> some View {
        HStack(alignment: .top, spacing: AtmoTheme.Spacing.md) {
            AvatarView(url: post.authorAvatarURL, size: AtmoTheme.AvatarSize.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.authorDisplayName ?? "@\(post.authorHandle)")
                    .font(.caption.weight(.semibold))
                Text(post.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(AtmoTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Translation Banner (for reply-to post)

    @ViewBuilder
    private func replyTranslationBanner(post: PostItem, vm: ComposerViewModel) -> some View {
        let detectedLang = TranslationHelper.detectedLanguage(of: post.text)
        let langName = detectedLang.flatMap {
            Locale.current.localizedString(forLanguageCode: $0.languageCode?.identifier ?? "")
        } ?? "another language"

        HStack(spacing: AtmoTheme.Spacing.sm) {
            Image(systemName: "character.bubble")
                .foregroundStyle(AtmoColors.accent)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text("This post is in \(langName)")
                    .font(.caption.weight(.medium))
                Text("Tap to translate before replying")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showReplyTranslation = true
                didUseTranslation = true
                vm.includeTranslationDisclosure = true
            } label: {
                Text("Translate")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, AtmoTheme.Spacing.sm)
                    .padding(.vertical, 5)
                    .background { Capsule().fill(AtmoColors.accent) }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.sm)
        .background(AtmoColors.accent.opacity(0.07))
    }
}

// MARK: - SlotComposerRow
// One post in the thread, laid out like a Threads slot:
//   • Avatar column with a vertical connector line reaching the next slot
//     (and the "Add to thread" ghost row after the last slot)
//   • Bold username line, with an ✕ remove control for extra slots
//   • The growing text field directly under the username
//   • A media icon row (photo picker — the Bluesky-supported subset of
//     Threads' attachment icons), per slot rather than per composer
//   • Image thumbnails with a remove button and an ALT badge that opens
//     the alt-text editor
//   • The quoted post card (first slot only)
private struct SlotComposerRow: View {
    @Bindable var slot: PostSlot
    let avatarURL: URL?
    let handle: String?
    let isFirst: Bool
    let isLast: Bool
    let canRemove: Bool
    /// Non-nil for the first slot when composing a quote post
    let showQuotedPost: PostItem?
    let onRemove: () -> Void

    // Photo picking is per-slot (each Threads slot owns its media).
    @State private var selectedItems: [PhotosPickerItem] = []

    // Alt-text editor state
    @State private var editingAltImageID: UUID? = nil
    @State private var altTextDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {

                // ── Avatar column ──
                // The connector line runs under the avatar to the next slot
                // (every slot: the "Add to thread" row continues the thread).
                VStack(spacing: 0) {
                    AvatarView(url: avatarURL, size: AtmoTheme.AvatarSize.medium)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 4)
                }
                .frame(width: AtmoTheme.AvatarSize.medium)

                // ── Text + accessories ──
                VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {

                    // Bold username line (Threads-style) + remove control
                    HStack(alignment: .center) {
                        Text(handle ?? "you")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if canRemove {
                            Button(action: onRemove) {
                                Image(systemName: "xmark")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Growing text field directly under the username
                    TextField(
                        isFirst
                            ? (showQuotedPost != nil ? "Add a comment…" : "What's new?")
                            : "Say more…",
                        text: $slot.text,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(minHeight: 44, alignment: .topLeading)

                    // Attached images strip
                    if !slot.attachedImages.isEmpty {
                        attachedImagesRow
                            .padding(.vertical, AtmoTheme.Spacing.xs)
                    }

                    // Media icon row — the Bluesky-supported subset of
                    // Threads' attachment icons.
                    mediaIconRow
                        .padding(.top, 2)

                    // Quote post card (first slot only)
                    if let quoted = showQuotedPost {
                        quotePreviewCard(post: quoted)
                            .padding(.top, AtmoTheme.Spacing.xs)
                            .padding(.bottom, AtmoTheme.Spacing.sm)
                    }
                }
            }
            .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
            .padding(.top, AtmoTheme.Feed.verticalPadding)
            // The connector line provides the visual gap below.
            .padding(.bottom, AtmoTheme.Spacing.xs)
        }
        // Alt-text editor (Bluesky accessibility feature)
        .alert(
            "Alt Text",
            isPresented: Binding(
                get: { editingAltImageID != nil },
                set: { if !$0 { editingAltImageID = nil } }
            )
        ) {
            TextField("Describe this image", text: $altTextDraft)
            Button("Save") {
                if let id = editingAltImageID,
                   let idx = slot.attachedImages.firstIndex(where: { $0.id == id }) {
                    slot.attachedImages[idx].altText = altTextDraft
                }
                editingAltImageID = nil
            }
            Button("Cancel", role: .cancel) { editingAltImageID = nil }
        } message: {
            Text("Alt text describes the image for people using screen readers.")
        }
    }

    // MARK: - Media icon row

    private var mediaIconRow: some View {
        let imageCount = slot.attachedImages.count
        return HStack(spacing: AtmoTheme.Spacing.lg) {
            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 4 - imageCount,
                matching: .images
            ) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.body)
                    .foregroundStyle(imageCount >= 4 ? Color.secondary.opacity(0.4) : Color.secondary)
            }
            .disabled(imageCount >= 4)
            .onChange(of: selectedItems) { _, newItems in
                Task { @MainActor in
                    await loadImages(from: newItems)
                }
            }

            if imageCount > 0 {
                Text("\(imageCount)/4")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    /// Loads image data from PhotosPicker items and appends them to this slot.
    @MainActor
    private func loadImages(from items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let fileName = item.itemIdentifier ?? "image_\(UUID().uuidString)"
            slot.addImage(data: data, fileName: "\(fileName).jpg")
        }
        selectedItems = []
    }

    // MARK: - Image strip

    private var attachedImagesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                ForEach(slot.attachedImages) { img in
                    ZStack(alignment: .topTrailing) {
                        if let uiImage = platformImage(from: img.data) {
                            Image(platformImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(
                                    cornerRadius: AtmoTheme.CornerRadius.small,
                                    style: .continuous
                                ))
                        }

                        Button {
                            slot.removeImage(id: img.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                    // ALT badge (bottom-leading) — tap to edit alt text,
                    // filled once alt text exists (matching Bluesky's app).
                    .overlay(alignment: .bottomLeading) {
                        Button {
                            altTextDraft = img.altText
                            editingAltImageID = img.id
                        } label: {
                            Text(img.altText.isEmpty ? "+ALT" : "ALT")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        img.altText.isEmpty
                                            ? Color.black.opacity(0.6)
                                            : AtmoColors.accent
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                    }
                }
            }
        }
    }

    // MARK: - Quote preview card

    private func quotePreviewCard(post: PostItem) -> some View {
        VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                AvatarView(url: post.authorAvatarURL, size: 18)
                if let name = post.authorDisplayName {
                    Text(name).font(.caption.weight(.semibold))
                }
                Text("@\(post.authorHandle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !post.text.isEmpty {
                Text(post.text)
                    .font(.callout)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AtmoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphicGlassCard()
    }

    // MARK: - Helpers

    private func platformImage(from data: Data) -> PlatformImage? {
#if os(iOS)
        UIImage(data: data)
#else
        NSImage(data: data)
#endif
    }
}

// MARK: - Platform Image Type Alias
#if os(iOS)
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif os(macOS)
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif
