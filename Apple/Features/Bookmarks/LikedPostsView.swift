import SwiftUI
import AtmoCore

// MARK: - LikedPostsView
// The ♥ library section: every post the user liked from this app,
// newest first — recorded by LikedPostsStore as likes land and synced
// via iCloud KVS (like bookmarks, invisible in iCloud Drive). Tapping a
// row opens the thread; the context menu removes an entry from the
// history (without touching the like on Bluesky).
struct LikedPostsView: View {

    /// When non-nil (iPad/macOS split view), navigation uses the shared parent
    /// NavigationStack in AppNavigation. When nil (iPhone), owns its own stack.
    var splitNavPath: Binding<NavigationPath>? = nil
    @State private var ownedNavPath = NavigationPath()

    @Environment(ATProtoService.self) private var service

    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    var body: some View {
        if splitNavPath != nil {
            likedContent
        } else {
            NavigationStack(path: $ownedNavPath) {
                likedContent
                    .navigationTitle("Liked")
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .navigationDestination(for: PostNavTarget.self) { target in
                        ThreadView(postURI: target.uri)
                            .themedBackdrop()
                    }
                    .themedBackdrop()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var likedContent: some View {
        let store = LikedPostsStore.shared
        Group {
            if store.likedPosts.isEmpty {
                VStack(spacing: AtmoTheme.Spacing.md) {
                    ContentUnavailableView(
                        "No Liked Posts Yet",
                        systemImage: "heart",
                        description: Text("Posts you like will collect here so you can look back on them.")
                    )
                    if store.isBackfilling {
                        syncingFooter
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.likedPosts) { liked in
                            LikedPostRow(liked: liked)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    navPath.wrappedValue = NavigationPath([PostNavTarget(uri: liked.uri)])
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        withAnimation {
                                            store.remove(uri: liked.uri)
                                        }
                                    } label: {
                                        Label("Remove from History", systemImage: "heart.slash")
                                    }
                                }
                            Divider().overlay(Color.secondary.opacity(0.1))
                        }

                        if store.isBackfilling {
                            syncingFooter
                                .padding(.vertical, AtmoTheme.Spacing.lg)
                        }
                    }
                }
            }
        }
        // Trickle in past likes (posts only) from the account's own like
        // records — a few pages per visit, cursor-resumed across visits.
        .task(id: service.currentUserDID) {
            await LikedPostsStore.shared.continueBackfill(service: service)
        }
    }

    private var syncingFooter: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Syncing past likes…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Liked Post Row
private struct LikedPostRow: View {
    let liked: LikedPost

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            AvatarView(url: liked.authorAvatarURL, size: AtmoTheme.Feed.avatarSize)

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    if let name = liked.authorDisplayName {
                        Text(name)
                            .font(AtmoFonts.authorName)
                            .lineLimit(1)
                    }
                    Text("@\(liked.authorHandle)")
                        .font(AtmoFonts.authorHandle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(liked.indexedAt.atmoFormatted())
                        .font(AtmoFonts.timestamp)
                        .foregroundStyle(.tertiary)
                }

                if !liked.text.isEmpty {
                    Text(liked.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }

                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(AtmoColors.likeRed)
                    Text("Liked \(liked.likedAt.atmoFormatted())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Feed.verticalPadding)
    }
}
