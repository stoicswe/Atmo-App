import SwiftUI
import AtmoCore

/// Sign-in for the watch. Credentials are entered with the system text
/// input (dictation / scribble / keyboard); once signed in, the session
/// persists in the Keychain like on the other platforms.
struct WatchLoginView: View {
    @Environment(ATProtoService.self) private var service
    @State private var viewModel = AuthViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Atmo")
                    .font(.title3.bold())

                if service.requiresTwoFactor {
                    twoFactorFields
                } else {
                    credentialFields
                }

                if service.authError != nil {
                    Text("Sign-in failed. Check your handle and App Password.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var credentialFields: some View {
        VStack(spacing: 8) {
            TextField("Handle", text: $viewModel.handle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("App Password", text: $viewModel.appPassword)

            Button {
                Task {
                    await service.login(
                        handle: viewModel.normalizedHandle,
                        appPassword: viewModel.appPassword
                    )
                }
            } label: {
                if service.isLoading {
                    ProgressView()
                } else {
                    Text("Sign In")
                }
            }
            .disabled(!viewModel.canSubmit || service.isLoading)
        }
    }

    private var twoFactorFields: some View {
        VStack(spacing: 8) {
            Text("Enter the code Bluesky emailed you.")
                .font(.footnote)
                .multilineTextAlignment(.center)
            TextField("2FA Code", text: $viewModel.twoFactorCode)
            Button("Confirm") {
                service.submitTwoFactorCode(viewModel.twoFactorCode)
            }
            .disabled(!viewModel.canSubmitTwoFactor)
        }
    }
}
