import SwiftUI
import PhotosUI

// MARK: - ComposerToolbar
// Bottom toolbar for the thread composer.
//
// The character counter and photo picker operate on the *active slot*
// (the last slot in the thread, which is where the user is currently typing).
// The Post / Thread button is enabled only when every slot satisfies canSubmit.
struct ComposerToolbar: View {
    @Bindable var viewModel: ComposerViewModel
    @State private var showPhotoPicker = false
    @State private var selectedItems: [PhotosPickerItem] = []

    // Derived from the active slot so SwiftUI re-renders when it changes.
    private var activeSlot: PostSlot { viewModel.activeSlot }

    var body: some View {
        // Capture count as a plain Int (Sendable) before entering closures —
        // avoids Swift 6 main-actor isolation warnings in PhotosPicker / onChange.
        let imageCount = activeSlot.attachedImages.count
        let remaining  = activeSlot.remainingCharacters

        HStack(spacing: AtmoTheme.Spacing.md) {

            // ── Photo picker (operates on the active slot) ──
            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 4 - imageCount,
                matching: .images
            ) {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(imageCount >= 4 ? Color.secondary : AtmoColors.skyBlue)
            }
            .disabled(imageCount >= 4)
            .onChange(of: selectedItems) { _, newItems in
                Task { @MainActor in
                    await loadImages(from: newItems, into: activeSlot)
                }
            }

            // ── Language indicator ──
            Image(systemName: "globe")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer()

            // ── Character counter (active slot) ──
            Text("\(remaining)")
                .font(AtmoFonts.characterCount)
                .foregroundStyle(
                    remaining < 0  ? .red :
                    remaining < 20 ? .orange :
                    .secondary
                )
                .animation(.easeInOut(duration: 0.2), value: remaining)
                .monospacedDigit()

            // ── Divider ──
            Divider().frame(height: 24)

            // ── Post / Thread button ──
            // Label changes from "Post" to "Thread" when more than one slot exists.
            Button {
                Task { await viewModel.submit() }
            } label: {
                if viewModel.isSubmitting {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 70, height: 32)
                } else {
                    Text(viewModel.slots.count > 1 ? "Thread" : "Post")
                        .fontWeight(.semibold)
                        .frame(width: 70, height: 32)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AtmoColors.skyBlue)
            .disabled(!viewModel.canSubmitThread)
            .animation(.easeInOut(duration: 0.15), value: viewModel.slots.count)
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.sm)
        .background(.regularMaterial)
    }

    // MARK: - Image loading

    /// Loads image data from PhotosPicker items and appends them to the given slot.
    @MainActor
    private func loadImages(from items: [PhotosPickerItem], into slot: PostSlot) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let fileName = item.itemIdentifier ?? "image_\(UUID().uuidString)"
            slot.addImage(data: data, fileName: "\(fileName).jpg")
        }
        selectedItems = []
    }
}
