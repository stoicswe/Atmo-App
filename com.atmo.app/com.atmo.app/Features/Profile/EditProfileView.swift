import SwiftUI
import PhotosUI

// MARK: - EditProfileView
// Liquid Glass sheet for editing the current user's display name, bio, and avatar.
// Replaces the plain Form with a custom card-based layout using the app's design system.

struct EditProfileView: View {
    let profile: ProfileModel
    let viewModel: ProfileViewModel

    @Environment(\.dismiss) private var dismiss

    // Form state — seeded from the current profile on appear
    @State private var displayName: String = ""
    @State private var bio: String = ""

    // Avatar picking
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var pendingAvatarData: Data? = nil
    @State private var pendingAvatarImage: Image? = nil

    // Submission state
    @State private var isSaving = false
    @State private var saveError: String? = nil

    // Field focus
    @FocusState private var focusedField: Field?
    private enum Field { case displayName, bio }

    private let maxBioLength = 256
    private let maxDisplayNameLength = 64

    var body: some View {
        ZStack {
            // Subtle tinted backdrop so glass cards read cleanly
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: AtmoTheme.Spacing.lg) {

                    headerRow
                        .padding(.horizontal, AtmoTheme.Spacing.xs)

                    avatarSection

                    fieldsSection

                    if let err = saveError {
                        errorBanner(err)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer(minLength: AtmoTheme.Spacing.xxxl)
                }
                .padding(.horizontal, AtmoTheme.Spacing.lg)
                .padding(.top, AtmoTheme.Spacing.lg)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: saveError != nil)
            }
        }
        // Load photo data when user selects an image from the picker
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    pendingAvatarData = data
                    pendingAvatarImage = swiftUIImage(from: data)
                }
            }
        }
        .onAppear {
            displayName = profile.displayName ?? ""
            bio = profile.description ?? ""
        }
    }

    // MARK: - Header row (title + Cancel / Save)

    private var headerRow: some View {
        HStack(alignment: .center) {
            Button("Cancel") { dismiss() }
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer()

            Text("Edit Profile")
                .font(.headline)

            Spacer()

            // Save / spinner — fixed-width so title stays centred
            Group {
                if isSaving {
                    ProgressView()
                        .tint(AtmoColors.skyBlue)
                } else {
                    Button("Save") {
                        Task { await save() }
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AtmoColors.skyBlue)
                    .disabled(isSaving)
                }
            }
            .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - Avatar section

    private var avatarSection: some View {
        VStack(spacing: AtmoTheme.Spacing.sm) {

            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                ZStack(alignment: .bottomTrailing) {
                    // Avatar
                    Group {
                        if let pending = pendingAvatarImage {
                            pending
                                .resizable()
                                .scaledToFill()
                                .frame(width: 90, height: 90)
                                .clipShape(Circle())
                        } else {
                            AvatarView(url: profile.avatarURL, size: 90)
                        }
                    }
                    .overlay {
                        // Subtle glass rim
                        Circle()
                            .strokeBorder(AtmoColors.glassBorder, lineWidth: 1.5)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

                    // Camera badge — glass pill
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .frame(width: 30, height: 30)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AtmoColors.skyBlue)
                    }
                    .offset(x: 3, y: 3)
                }
            }
            .buttonStyle(.plain)

            Text("Tap to change photo")
                .font(.caption)
                .foregroundStyle(AtmoColors.skyBlue)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AtmoTheme.Spacing.xl)
        .glassCard(cornerRadius: AtmoTheme.CornerRadius.large)
    }

    // MARK: - Stacked fields glass card

    private var fieldsSection: some View {
        VStack(spacing: 0) {

            // ── Display name ──
            fieldRow(
                label: "Display Name",
                icon: "person.fill",
                characterCount: displayName.count,
                maxCount: maxDisplayNameLength
            ) {
                TextField("Your name", text: $displayName)
                    .focused($focusedField, equals: .displayName)
                    .font(.body)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .bio }
                    .onChange(of: displayName) { _, new in
                        if new.count > maxDisplayNameLength {
                            displayName = String(new.prefix(maxDisplayNameLength))
                        }
                    }
            }

            // Inter-field divider, indented past the icon
            Divider()
                .overlay(AtmoColors.glassDivider)
                .padding(.leading, 52)

            // ── Bio ──
            fieldRow(
                label: "Bio",
                icon: "text.alignleft",
                characterCount: bio.count,
                maxCount: maxBioLength
            ) {
                ZStack(alignment: .topLeading) {
                    // Placeholder text
                    if bio.isEmpty {
                        Text("Tell everyone about yourself…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .padding(.top, 1)
                    }
                    TextEditor(text: $bio)
                        .focused($focusedField, equals: .bio)
                        .font(.body)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .background(.clear)
                        .onChange(of: bio) { _, new in
                            if new.count > maxBioLength {
                                bio = String(new.prefix(maxBioLength))
                            }
                        }
                }
            }
        }
        .glassCard(cornerRadius: AtmoTheme.CornerRadius.large)
    }

    // MARK: - Reusable field row

    @ViewBuilder
    private func fieldRow<Content: View>(
        label: String,
        icon: String,
        characterCount: Int,
        maxCount: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: AtmoTheme.Spacing.md) {

            // Icon chip
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AtmoColors.skyBlue.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AtmoColors.skyBlue)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                content()

                // Character counter
                Text("\(characterCount)/\(maxCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(
                        characterCount >= maxCount
                            ? Color.red
                            : Color.secondary.opacity(0.55)
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .animation(.easeInOut(duration: 0.15), value: characterCount >= maxCount)
            }
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.md)
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.subheadline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(AtmoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: AtmoTheme.CornerRadius.medium)
        .overlay {
            RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)
                .strokeBorder(Color.red.opacity(0.40), lineWidth: 1)
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        saveError = nil
        focusedField = nil
        await viewModel.updateProfile(
            displayName: displayName,
            description: bio,
            avatarData: pendingAvatarData
        )
        isSaving = false
        if viewModel.error == nil {
            dismiss()
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                saveError = viewModel.error?.localizedDescription ?? "Update failed."
            }
        }
    }

    // MARK: - Platform image helpers

    private func swiftUIImage(from data: Data) -> SwiftUI.Image? {
#if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return SwiftUI.Image(uiImage: uiImage)
#elseif os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return SwiftUI.Image(nsImage: nsImage)
#endif
    }
}
