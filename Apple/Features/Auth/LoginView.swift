import SwiftUI
import AtmoCore

struct LoginView: View {
    @Environment(ATProtoService.self) private var service
    @State private var viewModel = AuthViewModel()
    @State private var showTwoFactor = false
    @FocusState private var focusedField: LoginField?

    enum LoginField { case handle, password }

    var body: some View {
        ZStack {
            // Sky gradient background
            AtmoColors.skyGradient
                .ignoresSafeArea()

            // Subtle animated blobs for depth
            GeometryReader { geo in
                Circle()
                    .fill(AtmoColors.accent.opacity(0.18))
                    .frame(width: geo.size.width * 0.7)
                    .blur(radius: 80)
                    .offset(x: -geo.size.width * 0.2, y: -geo.size.height * 0.1)

                Circle()
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: geo.size.width * 0.6)
                    .blur(radius: 60)
                    .offset(x: geo.size.width * 0.4, y: geo.size.height * 0.5)
            }
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: AtmoTheme.Spacing.xxxl) {
                    Spacer(minLength: 60)

                    // App Icon + Name
                    VStack(spacing: AtmoTheme.Spacing.md) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [AtmoColors.accent, .white.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing)

                        Text("@omic")
                            .font(AtmoFonts.appTitle)
                        Text("for Bluesky")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Login Card
                    VStack(spacing: 0) {
                        // Handle field
                        HStack {
                            Image(systemName: "at")
                                .foregroundStyle(.tertiary)
                                .frame(width: 20)
                            TextField("handle.bsky.social", text: $viewModel.handle)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .handle)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
#if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
#endif
                        }
                        .padding(AtmoTheme.Spacing.lg)

                        // Hosting service, resolved from the handle as it's typed.
                        hostingServiceLine
                            .padding(.horizontal, AtmoTheme.Spacing.lg)
                            .padding(.bottom, AtmoTheme.Spacing.sm)

                        Divider()
                            .overlay(AtmoColors.glassDivider)

                        // Password field — the account password or an App Password.
                        HStack {
                            Image(systemName: "lock")
                                .foregroundStyle(.tertiary)
                                .frame(width: 20)
                            SecureField("Password or App Password", text: $viewModel.appPassword)
                                .textFieldStyle(.plain)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.go)
                                .onSubmit {
                                    if viewModel.canSubmit {
                                        Task { await performLogin() }
                                    }
                                }
                        }
                        .padding(AtmoTheme.Spacing.lg)
                    }
                    .glassCard(cornerRadius: AtmoTheme.CornerRadius.large)
                    .padding(.horizontal, AtmoTheme.Spacing.xxl)

                    // Error display
                    if let error = service.authError {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Sign In Button
                    VStack(spacing: AtmoTheme.Spacing.md) {
                        Button {
                            Task { await performLogin() }
                        } label: {
                            HStack {
                                if service.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("Sign In")
                                        .fontWeight(.semibold)
                                    Image(systemName: "arrow.right")
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(AtmoTheme.Spacing.lg)
                            .background(
                                viewModel.canSubmit ? AtmoColors.accent : Color.secondary.opacity(0.3)
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.large, style: .continuous))
                        }
                        .disabled(!viewModel.canSubmit || service.isLoading)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.canSubmit)

                        Text(viewModel.isAppPassword
                             ? "App Passwords sign in without a two-factor code."
                             : "Your account password works too. If two-factor is on,\nBluesky emails you a code to finish signing in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .animation(.easeInOut(duration: 0.2), value: viewModel.isAppPassword)
                    }
                    .padding(.horizontal, AtmoTheme.Spacing.xxl)

                    Spacer(minLength: 40)
                }
            }
        }
        .sheet(isPresented: $showTwoFactor) {
            TwoFactorView()
        }
        .onChange(of: service.requiresTwoFactor) { _, needs in
            showTwoFactor = needs
        }
        .onChange(of: viewModel.handle) { _, _ in
            viewModel.handleDidChange()
        }
    }

    /// "Signs in through bsky.social" — the resolved host, a spinner while
    /// resolving, or a note that the default host will be tried.
    @ViewBuilder
    private var hostingServiceLine: some View {
        HStack(spacing: 6) {
            if viewModel.isResolvingPDS {
                ProgressView()
                    .controlSize(.mini)
                Text("Finding hosting service…")
            } else if viewModel.resolvedPDS != nil {
                Image(systemName: "server.rack")
                Text("Signs in through \(viewModel.pdsDisplayHost)")
            } else if viewModel.pdsResolutionFailed {
                Image(systemName: "questionmark.circle")
                Text("Handle not found — will try \(viewModel.pdsDisplayHost)")
            } else {
                Image(systemName: "server.rack")
                Text("Signs in through \(viewModel.pdsDisplayHost)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 20 + AtmoTheme.Spacing.sm)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isResolvingPDS)
    }

    private func performLogin() async {
        await service.login(
            handle: viewModel.normalizedHandle,
            password: viewModel.appPassword,
            pdsURL: viewModel.resolvedPDS
        )
    }
}
