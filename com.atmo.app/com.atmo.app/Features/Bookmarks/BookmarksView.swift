import SwiftUI

// MARK: - BookmarksView
// Displays the user's iCloud-synced bookmarks as a scrollable list.
// Tapping a row navigates to the full thread. Swipe-to-delete removes the bookmark.
struct BookmarksView: View {

    /// When non-nil (iPad/macOS split view), navigation uses the shared parent
    /// NavigationStack in AppNavigation. When nil (iPhone), owns its own stack.
    var splitNavPath: Binding<NavigationPath>? = nil
    @State private var ownedNavPath = NavigationPath()

    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    var body: some View {
        if splitNavPath != nil {
            bookmarksContent
        } else {
            NavigationStack(path: $ownedNavPath) {
                bookmarksContent
                    .navigationTitle("Bookmarks")
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
#endif
                    .navigationDestination(for: PostNavTarget.self) { target in
                        ThreadView(postURI: target.uri)
                    }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var bookmarksContent: some View {
        let store = BookmarkStore.shared
        if store.bookmarks.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.bookmarks) { bookmark in
                        BookmarkRowView(bookmark: bookmark)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                navPath.wrappedValue = NavigationPath([PostNavTarget(uri: bookmark.uri)])
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation {
                                        if let idx = store.bookmarks.firstIndex(of: bookmark) {
                                            store.remove(at: IndexSet(integer: idx))
                                        }
                                    }
                                } label: {
                                    Label("Remove", systemImage: "bookmark.slash.fill")
                                }
                            }
                        Divider()
                            .overlay(Color.secondary.opacity(0.1))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Bookmarks",
            systemImage: "bookmark",
            description: Text("Tap the bookmark icon on any post to save it here.")
        )
    }
}

// MARK: - BookmarkRowView
// Compact row showing author info, post text snippet, and bookmark date.
private struct BookmarkRowView: View {
    let bookmark: BookmarkedPost

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            AvatarView(url: bookmark.authorAvatarURL, size: AtmoTheme.Feed.avatarSize)

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                // Author + timestamp
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    if let name = bookmark.authorDisplayName {
                        Text(name)
                            .font(AtmoFonts.authorName)
                            .lineLimit(1)
                    }
                    Text("@\(bookmark.authorHandle)")
                        .font(AtmoFonts.authorHandle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(bookmark.indexedAt.atmoFormatted())
                        .font(AtmoFonts.timestamp)
                        .foregroundStyle(.tertiary)
                }

                // Post text snippet
                if !bookmark.text.isEmpty {
                    Text(bookmark.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }

                // Bookmarked-at label
                HStack(spacing: 4) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                    Text("Saved \(bookmark.bookmarkedAt.atmoFormatted())")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Feed.verticalPadding)
    }
}
