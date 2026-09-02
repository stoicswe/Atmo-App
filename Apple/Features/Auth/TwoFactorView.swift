import SwiftUI
import AtmoCore

struct TwoFactorView: View {
    @Environment(ATProtoService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = AuthViewModel()
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AtmoColors.skyGradient
                    .ignoresSafeArea()

                VStack(spacing: AtmoTheme.Spacing.xxl) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(AtmoColors.accent)
                        .symbolEffect(.pulse)

                    VStack(spacing: AtmoTheme.Spacing.sm) {
                        Text("Two-Factor Authentication")
                            .font(.title2.weight(.bold))
                        Text("Bluesky emailed you a sign-in code. Enter it to finish signing in.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // Code field
                    TextField("XXXXX-XXXXX", text: $viewModel.twoFactorCode)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .autocorrectionDisabled()
#if os(iOS)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .textContentType(.oneTimeCode)
#endif
                        .focused($isFocused)
                        .padding(AtmoTheme.Spacing.xl)
                        .glassCard()
                        .padding(.horizontal, AtmoTheme.Spacing.xxl)
                        .onChange(of: viewModel.twoFactorCode) { _, new in
                            // Bluesky's emailed codes are XXXXX-XXXXX; keep
                            // the field to that shape's length.
                            let cleaned = new.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
                            let limited = String(cleaned.prefix(11))
                            if limited != new { viewModel.twoFactorCode = limited }
                        }

                    // A rejected code lands here; the sheet stays up for a retry.
                    if let error = service.authError {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, AtmoTheme.Spacing.xxl)
                    }

                    Button {
                        Task { await service.verifyTwoFactorCode(viewModel.twoFactorCode) }
                    } label: {
                        HStack {
                            if service.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Verify")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(AtmoColors.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.large, style: .continuous))
                    }
                    .disabled(!viewModel.canSubmitTwoFactor || service.isLoading)
                    .padding(.horizontal, AtmoTheme.Spacing.xxl)
                }
                .padding()
            }
            .navigationTitle("Verify Identity")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        service.cancelTwoFactor()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { Task { @MainActor in isFocused = true } }
        // Signed in: the login screen goes away underneath; close the sheet too.
        .onChange(of: service.isAuthenticated) { _, signedIn in
            if signedIn { dismiss() }
        }
        .interactiveDismissDisabled()
    }
}
