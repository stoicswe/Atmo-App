import SwiftUI

struct ProfileHeaderView: View {
    let profile: ProfileModel
    let isOwnProfile: Bool
    let onFollowTap: () -> Void
    /// Only needed for own profile — passed through to EditProfileView.
    var viewModel: ProfileViewModel? = nil

    @State private var showEditProfile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Banner
            ZStack(alignment: .bottomLeading) {
                // Banner image
                if let bannerURL = profile.bannerURL {
                    AsyncCachedImage(url: bannerURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            LinearGradient(
                                colors: [AtmoColors.skyBlue.opacity(0.4), Color.indigo.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        }
                    }
                } else {
                    LinearGradient(
                        colors: [AtmoColors.skyBlue.opacity(0.4), Color.indigo.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(height: 140)
            .clipped()
            // Extend the banner behind the sidebar column on iPad/macOS split view.
            // The detail column has a leading safe-area inset equal to the sidebar width;
            // ignoring it lets the banner image fill the full window width underneath
            // the translucent sidebar panel while keeping all other content inset normally.
            .ignoresSafeArea(.container, edges: .leading)

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
                        .background {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .overlay {
                            Capsule()
                                .strokeBorder(AtmoColors.glassBorder, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, AtmoTheme.Spacing.md)
                } else {
                    Button {
                        onFollowTap()
                    } label: {
                        Text(profile.isFollowing ? "Following" : "Follow")
                            .fontWeight(.semibold)
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(profile.isFollowing ? .secondary : AtmoColors.skyBlue)
                    .controlSize(.regular)
                    .padding(.top, AtmoTheme.Spacing.md)
                }
            }
            .padding(.horizontal, AtmoTheme.Spacing.lg)

            // Bio section
            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                if let name = profile.displayName, !name.isEmpty {
                    Text(name)
                        .font(.title3.weight(.bold))
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
