import SwiftUI
import AtmoCore

/// Applies the split-view banner bleed (under the translucent sidebar) on
/// iPad/macOS only — never on iPhone, where no sidebar inset exists.
private struct SplitLeadingBleed: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            content
        } else {
            content.ignoresSafeArea(.container, edges: .leading)
        }
#else
        content.ignoresSafeArea(.container, edges: .leading)
#endif
    }
}

struct ProfileHeaderView: View {
    let profile: ProfileModel
    let isOwnProfile: Bool
    let onFollowTap: () -> Void
    /// Only needed for own profile — passed through to EditProfileView.
    var viewModel: ProfileViewModel? = nil

    /// On iPhone the profile scroll ignores the top safe area so the
    /// banner runs to the physical top edge — the extra height here sits
    /// behind the status bar, keeping ~130pt of banner visible below it.
    static var bannerHeight: CGFloat {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 200 : 140
#else
        140
#endif
    }

    @State private var showEditProfile = false
    @State private var showBlockConfirm = false
    @State private var showUnblockConfirm = false
    /// Presented via `.sheet(item:)` so re-renders of the header never
    /// recreate the report flow mid-way.
    @State private var reportViewModel: ReportAccountViewModel? = nil
    @Environment(ATProtoService.self) private var service
    @Environment(\.authorSearch) private var authorSearch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Banner — a proposal-sized Color with the artwork as a
            // BACKGROUND. A background can never influence layout, so the
            // image's intrinsic size (height × aspect for scaledToFill) is
            // structurally incapable of inflating the header stack — which
            // is what shifted every profile row off the left edge once the
            // banner grew taller.
            Color.clear
                .frame(height: Self.bannerHeight)
                .frame(maxWidth: .infinity)
                .background {
                    if let bannerURL = profile.bannerURL {
                        AsyncCachedImage(url: bannerURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                LinearGradient(
                                    colors: [AtmoColors.accent.opacity(0.4), Color.indigo.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            }
                        }
                    } else {
                        LinearGradient(
                            colors: [AtmoColors.accent.opacity(0.4), Color.indigo.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .clipped()
            // See bannerHeight: the extra phone height sits behind the
            // status bar, keeping the visible banner portion consistent.
            // Extend the banner behind the sidebar column on iPad/macOS split view.
            // The detail column has a leading safe-area inset equal to the sidebar width;
            // ignoring it lets the banner image fill the full window width underneath
            // the translucent sidebar panel while keeping all other content inset normally.
            //
            // iPad/macOS ONLY: on iPhone (whose scroll ignores the TOP safe
            // area for the edge-to-edge banner) this leading ignore expanded
            // the lazy stack's bounds and shoved the whole profile column
            // off the left edge.
            .modifier(SplitLeadingBleed())

            // Avatar row
            HStack(alignment: .top) {
                AvatarView(url: profile.avatarURL, size: AtmoTheme.AvatarSize.profile)
                    .overlay(
                        Circle()
                            .stroke(Color.background(), lineWidth: 3)
                    )
                    .offset(y: -30)

                Spacer()

                // Follow / Edit button
                if isOwnProfile {
                    Button {
                        showEditProfile = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "pencil")
                                .font(.caption.weight(.bold))
                            Text("Edit Profile")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, AtmoTheme.Spacing.md)
                        .padding(.vertical, AtmoTheme.Spacing.xs)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, AtmoTheme.Spacing.md)
                } else {
                    HStack(spacing: AtmoTheme.Spacing.sm) {
                        if viewModel != nil {
                            profileMenu
                        }

                        if profile.isBlocking {
                            // Official-app behavior: a blocked account shows
                            // "Blocked" where Follow would be; tapping unblocks.
                            Button {
                                showUnblockConfirm = true
                            } label: {
                                Text("Blocked")
                                    .fontWeight(.semibold)
                                    .frame(minWidth: 80)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.regular)
                        } else {
                            Button {
                                onFollowTap()
                            } label: {
                                Text(profile.isFollowing ? "Following" : "Follow")
                                    .fontWeight(.semibold)
                                    .frame(minWidth: 80)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(profile.isFollowing ? .secondary : AtmoColors.accent)
                            .controlSize(.regular)
                        }

                        subscriptionBell
                    }
                    .padding(.top, AtmoTheme.Spacing.md)
                }
            }
            .padding(.horizontal, AtmoTheme.Spacing.lg)

            // Bio section
            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                if let name = profile.displayName, !name.isEmpty {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.title3.weight(.bold))
                        if let badge = profile.verification {
                            VerifiedBadge(badge: badge, size: 15)
                        }
                    }
                } else if let badge = profile.verification {
                    VerifiedBadge(badge: badge, size: 15)
                }
                Text("@\(profile.handle)")
                    .font(AtmoFonts.handle)
                    .foregroundStyle(.secondary)

                if let bio = profile.description, !bio.isEmpty {
                    Text(bio)
                        .font(.body)
                        .padding(.top, AtmoTheme.Spacing.xs)
                }

                // Stats row
                HStack(spacing: AtmoTheme.Spacing.xl) {
                    statItem(count: profile.followsCount, label: "Following")
                    statItem(count: profile.followersCount, label: "Followers")
                    statItem(count: profile.postsCount, label: "Posts")
                }
                .padding(.top, AtmoTheme.Spacing.sm)

                // Moderation state chips — mirrors the "Reposts Hidden"
                // pill on the web app.
                if !isOwnProfile {
                    let hidingReposts = viewModel?.isHidingReposts ?? false
                    if hidingReposts || profile.isMuted || profile.isBlocking {
                        HStack(spacing: AtmoTheme.Spacing.sm) {
                            if profile.isBlocking {
                                statusChip("Blocked", systemImage: "person.crop.circle.badge.xmark")
                            }
                            if profile.isMuted {
                                statusChip("Muted", systemImage: "speaker.slash")
                            }
                            if hidingReposts {
                                statusChip("Reposts hidden", systemImage: "arrow.2.squarepath")
                            }
                        }
                        .padding(.top, AtmoTheme.Spacing.sm)
                    }
                }
            }
            .padding(.horizontal, AtmoTheme.Spacing.lg)
            .padding(.bottom, AtmoTheme.Spacing.md)
        }
        .sheet(isPresented: $showEditProfile) {
            if let vm = viewModel {
                EditProfileView(profile: profile, viewModel: vm)
                    .themedBackdrop()
            }
        }
        .sheet(item: $reportViewModel) { reportVM in
            ReportAccountView(
                viewModel: reportVM,
                isBlocking: profile.isBlocking,
                onBlock: { Task { await viewModel?.toggleBlock() } }
            )
            .themedBackdrop()
        }
        .alert("Block @\(profile.handle)?", isPresented: $showBlockConfirm) {
            Button("Block", role: .destructive) {
                Haptics.thump()
                Task { await viewModel?.toggleBlock() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Blocked accounts cannot reply in your threads, mention you, or otherwise interact with you. You will not see their content and they will be prevented from seeing yours.")
        }
        .alert("Unblock @\(profile.handle)?", isPresented: $showUnblockConfirm) {
            Button("Unblock") {
                Haptics.soft()
                Task { await viewModel?.toggleBlock() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The account will be able to interact with you and see your posts again.")
        }
    }

    // MARK: - ··· menu
    // The web app's profile overflow: link + search up top, then the
    // moderation actions (hide reposts, mute, block, report).
    private var profileMenu: some View {
        let hidingReposts = viewModel?.isHidingReposts ?? false

        return Menu {
            Button {
                copyProfileLink()
            } label: {
                Label("Copy link to profile", systemImage: "link")
            }
            Button {
                Haptics.tap()
                authorSearch(profile.handle)
            } label: {
                Label("Search posts", systemImage: "magnifyingglass")
            }

            Divider()

            Button {
                Haptics.tap()
                viewModel?.setHidingReposts(!hidingReposts)
            } label: {
                Label(hidingReposts ? "Show reposts in feeds" : "Hide reposts in feeds",
                      systemImage: "arrow.2.squarepath")
            }
            Button {
                Haptics.tap()
                Task { await viewModel?.toggleMute() }
            } label: {
                Label(profile.isMuted ? "Unmute account" : "Mute account",
                      systemImage: profile.isMuted ? "speaker.wave.2" : "speaker.slash")
            }
            if profile.isBlocking {
                Button {
                    showUnblockConfirm = true
                } label: {
                    Label("Unblock account", systemImage: "person.crop.circle.badge.checkmark")
                }
            } else {
                Button(role: .destructive) {
                    showBlockConfirm = true
                } label: {
                    Label("Block account", systemImage: "person.crop.circle.badge.xmark")
                }
            }
            Button(role: .destructive) {
                reportViewModel = ReportAccountViewModel(
                    service: service,
                    subjectDID: profile.did,
                    subjectHandle: profile.handle
                )
            } label: {
                Label("Report account", systemImage: "flag")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 34, height: 34)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More options")
    }

    private func copyProfileLink() {
        guard let url = profile.bskyWebURL else { return }
        AtmoPasteboard.copy(url.absoluteString)
        Haptics.confirm()
    }

    private func statusChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, AtmoTheme.Spacing.sm)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    // MARK: - Post-notification subscription bell
    // Lets the user subscribe to this account's posts: All Posts (their
    // reposts included) or Original Posts Only. Delivered by the
    // battery-friendly background sync as local notifications; managed
    // later from Settings → Notifications.
    private var subscriptionBell: some View {
        let store = NotificationSettingsStore.shared
        let currentMode = store.subscription(for: profile.did)?.mode ?? .off

        return Menu {
            ForEach([UserPostNotificationMode.allPosts, .originalPostsOnly, .off]) { mode in
                Button {
                    store.setSubscription(
                        did: profile.did,
                        handle: profile.handle,
                        displayName: profile.displayName,
                        mode: mode
                    )
                    if mode != .off {
                        // Make sure the OS will actually deliver these.
                        Task { @MainActor in
                            _ = await Atmo.platform.alertPresenter.requestAuthorization()
                        }
                    }
                } label: {
                    if mode == currentMode || (mode == .off && currentMode == .off) {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: currentMode == .off ? "bell" : "bell.badge.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(currentMode == .off ? Color.secondary : AtmoColors.accent)
                .frame(width: 34, height: 34)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Post notifications: \(currentMode.displayName)")
    }

    private func statItem(count: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text(count.formatted(.number.notation(.compactName)))
                .fontWeight(.semibold)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

// Cross-platform background color helper
private extension Color {
    static func background() -> Color {
#if os(iOS)
        Color(UIColor.systemBackground)
#else
        Color(NSColor.windowBackgroundColor)
#endif
    }
}

private extension ProfileHeaderView {
    func uiOrNSColor(_ color: Any) -> Color {
#if os(iOS)
        if let c = color as? UIColor { return Color(c) }
#elseif os(macOS)
        if let c = color as? NSColor { return Color(c) }
#endif
        return .white
    }
}

// Workaround for platform-conditional inline
private func Color(uiOrNSColor: Any) -> SwiftUI.Color {
#if os(iOS)
    if let c = uiOrNSColor as? UIColor { return SwiftUI.Color(c) }
#elseif os(macOS)
    if let c = uiOrNSColor as? NSColor { return SwiftUI.Color(c) }
#endif
    return .white
}
