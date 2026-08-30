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

            Spacer()

            // ── Character budget (active slot) ──
            characterRing(remaining: remaining, progress: progress)

            // ── Post pill ──
            // Prominent Liquid Glass button: the system supplies the
            // capsule, tint, pressed states, and disabled dimming.
            Button {
                Task { await viewModel.submit() }
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
