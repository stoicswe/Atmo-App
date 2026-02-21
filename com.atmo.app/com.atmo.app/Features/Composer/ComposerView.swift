import SwiftUI
import Translation

// MARK: - ComposerView
// Full-screen sheet for composing a new post, a reply, or a quote post.
// Supports multi-post thread composition: each slot is a separate text entry
// with its own image attachments. Slots are stacked vertically with a thin
// connector line between the avatar column of consecutive posts.
//
// Draft behaviour:
//   • Text is auto-saved 400 ms after each keystroke via ComposerViewModel.
//   • Pressing Cancel with content shows a "Discard / Save Draft / Keep Editing"
//     confirmation. "Save Draft" explicitly saves and dismisses.
//   • Dismissing via any other path (swipe on iOS, click-outside or native
//     Cancel on macOS) auto-saves the draft when there is meaningful content,
//     then fires the draftSaved environment action to show the toast.
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

    var body: some View {
        NavigationStack {
            ZStack {
                // Background: thin glass
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

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
                                    showTranslationDisclosure: index == 0 && didUseTranslation
                                        ? Binding(
                                            get: { vm.includeTranslationDisclosure },
                                            set: { vm.includeTranslationDisclosure = $0 }
                                        )
                                        : nil,
                                    onRemove: { vm.removeSlot(id: slot.id) }
                                )
                                .focused($focusedSlotID, equals: slot.id)

                                // Connector line + "Add to thread" button between slots,
                                // and an "Add to thread" button after the last slot.
                                if index == vm.slots.count - 1 {
                                    addToThreadButton(vm: vm)
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
                        ComposerToolbar(viewModel: vm)
                    }
                }
            }
            .navigationTitle(quotedPost != nil ? "Quote Post" : replyTo != nil ? "Reply" : "New Post")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { handleCancel() }
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
            // Swipe-to-dismiss detection:
            // When the sheet is pulled down interactively, SwiftUI removes the view
            // without going through our Cancel button. We detect this via onDisappear —
            // if dismissedExplicitly is still false at that point, the user swiped.
            // We then ensure the draft is saved (the debounced auto-save may not have
            // flushed yet) and notify the caller to show a toast.
            .onDisappear {
                guard let vm = viewModel else { return }
                if !dismissedExplicitly && vm.hasMeaningfulContent {
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
        if vm.hasMeaningfulContent {
            // Show the action sheet — the user chooses Discard or Keep Editing.
            // dismissedExplicitly is set to true inside the Discard button action.
            showDiscardAlert = true
        } else {
            // Nothing to save — close cleanly without a draft.
            dismissedExplicitly = true
            vm.discardDraft()
            dismiss()
        }
    }

    // MARK: - Add to Thread Button

    private func addToThreadButton(vm: ComposerViewModel) -> some View {
        Button {
            vm.addSlot()
            // Focus the newly added slot after SwiftUI updates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedSlotID = vm.slots.last?.id
            }
        } label: {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                // Mini avatar placeholder aligned with the avatar column
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(
                        width: AtmoTheme.AvatarSize.medium * 0.6,
                        height: AtmoTheme.AvatarSize.medium * 0.6
                    )
                    .padding(.leading,
                        AtmoTheme.Feed.horizontalPadding +
                        (AtmoTheme.AvatarSize.medium - AtmoTheme.AvatarSize.medium * 0.6) / 2
                    )

                Text("Add to thread")
                    .font(.subheadline)
                    .foregroundStyle(AtmoColors.skyBlue)

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, AtmoTheme.Spacing.sm)
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
                .foregroundStyle(AtmoColors.skyBlue)
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
                    .background { Capsule().fill(AtmoColors.skyBlue) }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.sm)
        .background(AtmoColors.skyBlue.opacity(0.07))
    }
}

// MARK: - SlotComposerRow
// Renders a single post slot in the thread composer. Each slot shows:
//   • The user's avatar (with a vertical thread connector line below it when not last)
//   • An optional remove button (when the thread has more than 1 slot)
//   • A growing TextField for the post text
//   • An optional image attachment strip
//   • The quoted post card (first slot only)
//   • The translation disclosure toggle (first slot only, after using Translate)
private struct SlotComposerRow: View {
    @Bindable var slot: PostSlot
    let avatarURL: URL?
    let handle: String?
    let isFirst: Bool
    let isLast: Bool
    let canRemove: Bool
    /// Non-nil for the first slot when composing a quote post
    let showQuotedPost: PostItem?
    /// Non-nil for the first slot after the user has used translation
    var showTranslationDisclosure: Binding<Bool>?
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {

                // ── Avatar column ──
                // Includes the vertical connector line below the avatar
                // (except on the last slot).
                VStack(spacing: 0) {
                    AvatarView(url: avatarURL, size: AtmoTheme.AvatarSize.medium)

                    if !isLast {
                        // Connector line running from under this avatar to the next
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                            .padding(.top, 4)
                    }
                }
                .frame(width: AtmoTheme.AvatarSize.medium)

                // ── Text + accessories ──
                VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {

                    // Handle + optional remove button on the same line
                    HStack(alignment: .center) {
                        if let h = handle {
                            Text("@\(h)")
                                .font(AtmoFonts.handle)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if canRemove {
                            Button(action: onRemove) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Growing text field
                    TextField(
                        isFirst && slot.text.isEmpty
                            ? (showQuotedPost != nil ? "Add a comment…" : "What's on your mind?")
                            : "Continue the thread…",
                        text: $slot.text,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(minHeight: 80, alignment: .topLeading)

                    // Attached images strip
                    if !slot.attachedImages.isEmpty {
                        attachedImagesRow
                            .padding(.bottom, AtmoTheme.Spacing.xs)
                    }

                    // Quote post card (first slot only)
                    if let quoted = showQuotedPost {
                        quotePreviewCard(post: quoted)
                            .padding(.bottom, AtmoTheme.Spacing.sm)
                    }

                    // Translation disclosure toggle (first slot only)
                    if let disclosureBinding = showTranslationDisclosure {
                        translationDisclosureRow(isOn: disclosureBinding)
                            .padding(.bottom, AtmoTheme.Spacing.xs)
                    }
                }
            }
            .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
            .padding(.top, AtmoTheme.Feed.verticalPadding)
            // Bottom padding: smaller if there's a connector line below (it provides visual gap)
            .padding(.bottom, isLast ? AtmoTheme.Feed.verticalPadding : AtmoTheme.Spacing.xs)
        }
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
                                .frame(width: 80, height: 80)
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
                        .offset(x: 4, y: -4)
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
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(
            cornerRadius: AtmoTheme.CornerRadius.medium,
            style: .continuous
        ))
        .overlay(
            RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)
                .stroke(AtmoColors.glassBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Translation disclosure toggle

    private func translationDisclosureRow(isOn: Binding<Bool>) -> some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            Image(systemName: "character.bubble.fill")
                .font(.caption)
                .foregroundStyle(AtmoColors.skyBlue)
            Text("Add translation disclosure")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AtmoColors.skyBlue)
                .scaleEffect(0.8)
        }
        .padding(.horizontal, AtmoTheme.Spacing.md)
        .padding(.vertical, AtmoTheme.Spacing.xs)
        .background(AtmoColors.skyBlue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn.wrappedValue)
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
