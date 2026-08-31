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
            }
            .padding(.horizontal, AtmoTheme.Spacing.lg)
            .padding(.bottom, AtmoTheme.Spacing.md)
        }
        .sheet(isPresented: $showEditProfile) {
            if let vm = viewModel {
                EditProfileView(profile: profile, viewModel: vm)
            }
        }
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
