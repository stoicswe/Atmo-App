import Adwaita
import Foundation
import AtmoCore

extension MainView {

    /// Handle + App Password sign-in, with the 2FA code row appearing when
    /// the server asks for one — the same flow as the SwiftUI LoginView.
    @ViewBuilder var loginPage: Body {
        ScrollView {
            VStack(spacing: 12) {
                Text("@omic")
                    .style("title-1")
                Text("A Bluesky client")
                    .style("dim-label")

                Form {
                    EntryRow("Handle (e.g. alice.bsky.social)", text: $handle)
                    PasswordEntryRow("App Password", text: $appPassword)
                    if requiresTwoFactor {
                        EntryRow("2FA Code (emailed to you)", text: $twoFactorCode)
                    }
                }
                .padding(12)

                if requiresTwoFactor {
                    Button("Confirm Code") { submitTwoFactor() }
                        .style("suggested-action")
                        .pill()
                } else {
                    Button(isBusy ? "Signing In…" : "Sign In") { signIn() }
                        .style("suggested-action")
                        .pill()
                        .insensitive(!canSubmitLogin || isBusy)
                }

                if hasAuthError {
                    Text("Sign-in failed. Check your handle and App Password.")
                        .style("error")
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .valign(.center)
        }
        .vexpand()
    }

    var canSubmitLogin: Bool {
        !handle.trimmingCharacters(in: .whitespaces).isEmpty && !appPassword.isEmpty
    }

    var hasAuthError: Bool {
        _ = tick
        return onMain { AppSession.shared.service.authError != nil }
    }

    /// Normalizes like the shared AuthViewModel: strips a leading @ and
    /// assumes bsky.social for bare names.
    var normalizedHandle: String {
        var h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("@") { h = String(h.dropFirst()) }
        if !h.contains(".") { h = "\(h).bsky.social" }
        return h
    }

    func signIn() {
        let handle = normalizedHandle
        let password = appPassword
        runCore {
            await AppSession.shared.service.login(handle: handle, appPassword: password)
            if AppSession.shared.service.isAuthenticated {
                // Shared with the restore path: builds view models, starts
                // model observation, loads timeline + notifications.
                startSignedInSession()
            }
        }
    }

    func submitTwoFactor() {
        let code = twoFactorCode
        runCore {
            AppSession.shared.service.submitTwoFactorCode(code)
        }
    }
}
