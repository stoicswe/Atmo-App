import SwiftUI
import AtmoCore

// MARK: - ComposerToolbar
// Threads-style bottom bar for the composer:
//   • "Post Options" on the left — a popover with the Bluesky-supported
//     posting options (currently the translation disclosure toggle)
//   • A character-budget ring for the active slot (the last slot, where
//     the user is typing), with the remaining count once it gets tight
//   • The Post pill — filled when every slot is postable, muted otherwise;
//     its label switches to "Post All" for multi-post threads
struct ComposerToolbar: View {
    @Bindable var viewModel: ComposerViewModel
    /// Highlights the translation disclosure option after the user
    /// translated the post they're replying to.
    var showTranslationDisclosureOption: Bool = false

    @State private var showPostOptions = false
    @State private var showInteractionSettings = false

    // Derived from the active slot so SwiftUI re-renders when it changes.
    private var activeSlot: PostSlot { viewModel.activeSlot }

    var body: some View {
        let remaining = activeSlot.remainingCharacters
        let progress = min(1, max(0, Double(activeSlot.characterCount) / 300))

        HStack(spacing: AtmoTheme.Spacing.md) {

            // ── Post Options ──
            Button {
                showPostOptions = true
            } label: {
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Post Options")
                }
                .font(.subheadline)
            }
            .buttonStyle(.glass)
            .popover(isPresented: $showPostOptions, arrowEdge: .bottom) {
                postOptionsContent
            }

            // ── Interaction settings (who can reply / quoting) ──
            // Tinted accent once customized, so a gated post is visible
            // at a glance before hitting Post.
            Button {
                showInteractionSettings = true
            } label: {
                Image(systemName: "person.2")
                    .font(.subheadline)
                    .foregroundStyle(viewModel.interactionSettings.isDefault
                                     ? Color.secondary : AtmoColors.accent)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Post interaction settings")
            .sheet(isPresented: $showInteractionSettings) {
                PostInteractionSettingsSheet(viewModel: viewModel)
            }

            Spacer()

            // ── Character budget (active slot) ──
            characterRing(remaining: remaining, progress: progress)

            // ── Post pill ──
            // Prominent Liquid Glass button: the system supplies the
            // capsule, tint, pressed states, and disabled dimming.
            //
            // iOS hands the thread to PostPublisher and dismisses at once —
            // progress lives in the status pill and the Live Activity.
            // macOS keeps the in-sheet spinner (no Live Activity there).
            Button {
#if os(iOS)
                viewModel.submitInBackground()
#else
                Task { await viewModel.submit() }
#endif
            } label: {
                Group {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(viewModel.slots.count > 1 ? "Post All" : "Post")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(minWidth: 52)
            }
            .buttonStyle(.glassProminent)
            .tint(AtmoColors.accent)
            .disabled(!viewModel.canSubmitThread)
            .animation(.easeInOut(duration: 0.15), value: viewModel.canSubmitThread)
            .animation(.easeInOut(duration: 0.15), value: viewModel.slots.count)
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.sm)
        // No bar material: the controls are glass and float over the
        // sheet's own background, letting content scroll beneath them.
    }

    // MARK: - Character ring

    @ViewBuilder
    private func characterRing(remaining: Int, progress: Double) -> some View {
        HStack(spacing: AtmoTheme.Spacing.xs) {
            // Remaining count appears once the budget gets tight.
            if remaining < 50 {
                Text("\(remaining)")
                    .font(AtmoFonts.characterCount)
                    .foregroundStyle(remaining < 0 ? .red : .orange)
                    .monospacedDigit()
            }

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        remaining < 0 ? Color.red :
                        remaining < 50 ? Color.orange :
                        AtmoColors.accent,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
        }
        .animation(.easeInOut(duration: 0.2), value: remaining)
    }

    // MARK: - Post Options popover

    private var postOptionsContent: some View {
        VStack(alignment: .leading, spacing: AtmoTheme.Spacing.md) {
            Text("Post Options")
                .font(.headline)

            Toggle(isOn: Binding(
                get: { viewModel.includeTranslationDisclosure },
                set: { viewModel.includeTranslationDisclosure = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translation disclosure")
                        .font(.subheadline)
                    Text("Appends a note that the reply was translated with Apple Intelligence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(AtmoColors.accent)

            if showTranslationDisclosureOption {
                Label("You translated the post you're replying to.", systemImage: "character.bubble")
                    .font(.caption)
                    .foregroundStyle(AtmoColors.accent)
            }
        }
        .padding(AtmoTheme.Spacing.lg)
        .frame(minWidth: 280, maxWidth: 340)
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - Post Interaction Settings Sheet
// Bluesky-style controls: "Anyone" / "Nobody" as radio states, three
// combinable audience rules, and the quote-post toggle. For replies only
// the quote toggle applies — reply audience belongs to the thread's author.
struct PostInteractionSettingsSheet: View {
    let viewModel: ComposerViewModel
    @Environment(\.dismiss) private var dismiss

    private var isReply: Bool { viewModel.replyTo != nil }
    private var settings: PostInteractionSettings { viewModel.interactionSettings }

    var body: some View {
        NavigationStack {
            Form {
                if !isReply {
                    Section {
                        radioRow("Anyone", selected: settings.anyoneCanReply) {
                            update { s in
                                s.anyoneCanReply = true
                                s.mentionedCanReply = false
                                s.followingCanReply = false
                                s.followersCanReply = false
                            }
                        }
                        radioRow("Nobody", selected: settings.nobodyCanReply) {
                            update { s in
                                s.anyoneCanReply = false
                                s.mentionedCanReply = false
                                s.followingCanReply = false
                                s.followersCanReply = false
                            }
                        }
                        ruleRow("People you mention", isOn: settings.mentionedCanReply) {
                            update { s in
                                s.anyoneCanReply = false
                                s.mentionedCanReply.toggle()
                            }
                        }
                        ruleRow("People you follow", isOn: settings.followingCanReply) {
                            update { s in
                                s.anyoneCanReply = false
                                s.followingCanReply.toggle()
                            }
                        }
                        ruleRow("Your followers", isOn: settings.followersCanReply) {
                            update { s in
                                s.anyoneCanReply = false
                                s.followersCanReply.toggle()
                            }
                        }
                    } header: {
                        Text("Who can reply")
                    } footer: {
                        Text("Combine the checkboxes to allow several groups. Applies to threads you start.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { settings.allowQuotePosts },
                        set: { on in update { $0.allowQuotePosts = on } }
                    )) {
                        Label("Allow quote posts", systemImage: "quote.opening")
                    }
                    .tint(AtmoColors.accent)
                } footer: {
                    Text(isReply
                         ? "Who can reply is controlled by the thread's author; quoting applies to your reply."
                         : "Applied when the post is published.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Post Interactions")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { dismiss() }
                }
            }
        }
#if os(iOS)
        .presentationDetents([.medium, .large])
#endif
    }

    private func update(_ mutate: (inout PostInteractionSettings) -> Void) {
        var s = viewModel.interactionSettings
        mutate(&s)
        viewModel.interactionSettings = s
    }

    @ViewBuilder
    private func radioRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AtmoTheme.Spacing.md) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AtmoColors.accent : Color.secondary)
                Text(title)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func ruleRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AtmoTheme.Spacing.md) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? AtmoColors.accent : Color.secondary)
                Text(title)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
