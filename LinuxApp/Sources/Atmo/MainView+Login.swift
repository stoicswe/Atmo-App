import Adwaita
import Foundation
import AtmoCore

extension MainView {

    /// Handle + password sign-in against the account's own PDS, with the
    /// 2FA code row appearing when the server asks for one — the same
    /// flow as the SwiftUI LoginView (account password or App Password;
    /// only the former can trigger the emailed code).
    @ViewBuilder var loginPage: Body {
        ScrollView {
            VStack(spacing: 12) {
                Symbol(icon: .custom(name: "com.stoicswe.atmo"))
                    .pixelSize(96)
                    .style("icon-dropshadow")
                    .padding(8)
                Text("@omic")
                    .style("title-1")
                Text("A Bluesky client")
                    .style("dim-label")

                Form {
                    EntryRow("Handle or email", text: $handle)
                    PasswordEntryRow("Password or App Password", text: $appPassword)
                    if requiresTwoFactor {
                        EntryRow("Code (emailed to you)", text: $twoFactorCode)
                            .onSubmit { submitTwoFactor() }
                    }
                }
                .padding(12)

                if requiresTwoFactor {
                    Text("Check your email for a sign-in code.")
                        .style("dim-label")
                    HStack(spacing: 8) {
                        Button("Cancel") { cancelTwoFactor() }
                            .pill()
                        Button(isBusy ? "Verifying…" : "Confirm Code") { submitTwoFactor() }
                            .style("suggested-action")
                            .pill()
                            .insensitive(twoFactorCode.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                    }
                    .halign(.center)
                } else {
                    Button(isBusy ? "Signing In…" : "Sign In") { signIn() }
                        .style("suggested-action")
                        .pill()
                        .insensitive(!canSubmitLogin || isBusy)
                }

                if hasAuthError {
                    Text(authErrorText)
                        .wrap()
                        .justify(.center)
                        .style("error")
                }
                Text("Sessions are created on your account's own PDS; App Passwords never trigger two-factor.")
                    .wrap()
                    .justify(.center)
                    .style("dim-label")
                    .style("caption")
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

    var authErrorText: String {
        if requiresTwoFactor { return "That code wasn't accepted. Check your email and try again." }
        return "Sign-in failed. Check your handle and password."
    }

    /// Normalizes like the shared AuthViewModel: strips a leading @ and
    /// assumes bsky.social for bare names.
    var normalizedHandle: String {
        onMain {
            let auth = AuthViewModel()
            auth.handle = handle
            return auth.normalizedHandle
        }
    }

    func signIn() {
        let handle = normalizedHandle
        let password = appPassword
        runCore {
            await AppSession.shared.service.login(handle: handle, password: password, pdsURL: nil)
            if AppSession.shared.service.isAuthenticated {
                appPassword = ""
                twoFactorCode = ""
                // Shared with the restore path: builds view models, starts
                // model observation, loads timeline + notifications.
                startSignedInSession()
            }
        }
    }

    func submitTwoFactor() {
        let code = twoFactorCode
        runCore {
            await AppSession.shared.service.verifyTwoFactorCode(code)
            if AppSession.shared.service.isAuthenticated {
                appPassword = ""
                twoFactorCode = ""
                startSignedInSession()
            }
        }
    }

    func cancelTwoFactor() {
        twoFactorCode = ""
        onMain { AppSession.shared.service.cancelTwoFactor() }
        tick += 1
    }
}
