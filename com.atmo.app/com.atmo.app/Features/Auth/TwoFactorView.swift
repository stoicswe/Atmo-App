import SwiftUI

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
                        .foregroundStyle(AtmoColors.skyBlue)
                        .symbolEffect(.pulse)

                    VStack(spacing: AtmoTheme.Spacing.sm) {
                        Text("Two-Factor Authentication")
                            .font(.title2.weight(.bold))
                        Text("Enter the code from your authenticator app or email.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // Code field
                    TextField("000000", text: $viewModel.twoFactorCode)
                        .textFieldStyle(.plain)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .focused($isFocused)
                        .padding(AtmoTheme.Spacing.xl)
                        .glassCard()
                        .padding(.horizontal, AtmoTheme.Spacing.xxl)
                        .onChange(of: viewModel.twoFactorCode) { _, new in
                            // Limit to 6 characters
                            if new.count > 6 {
                                viewModel.twoFactorCode = String(new.prefix(6))
                            }
                        }

                    Button {
                        service.submitTwoFactorCode(viewModel.twoFactorCode)
                        dismiss()
                    } label: {
                        Text("Verify")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(AtmoColors.skyBlue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.large, style: .continuous))
                    }
                    .disabled(!viewModel.canSubmitTwoFactor)
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
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { Task { @MainActor in isFocused = true } }
    }
}
