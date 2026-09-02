import SwiftUI
import AtmoCore

// MARK: - Bookmark Picker
/// Pick one of the person's bookmarked posts to share into a chat. Rows
/// show author and a text preview; tapping sends and closes.
struct BookmarkPickerSheet: View {
    let onPick: (BookmarkedPost) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var bookmarks: [BookmarkedPost] {
        let all = BookmarkStore.shared.bookmarks
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.text.localizedCaseInsensitiveContains(trimmed)
                || $0.authorHandle.localizedCaseInsensitiveContains(trimmed)
                || ($0.authorDisplayName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if BookmarkStore.shared.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark",
                        description: Text("Posts you bookmark show up here, ready to send.")
                    )
                } else {
                    List(bookmarks) { bookmark in
                        Button {
                            Haptics.tap()
                            onPick(bookmark)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: AtmoTheme.Spacing.sm) {
                                AvatarView(url: bookmark.authorAvatarURLString.flatMap(URL.init(string:)), size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(bookmark.authorDisplayName ?? bookmark.authorHandle)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text("@\(bookmark.authorHandle)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    if !bookmark.text.isEmpty {
                                        Text(bookmark.text)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(3)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "paperplane")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .searchable(text: $query, prompt: "Search bookmarks")
                }
            }
            .navigationTitle("Send a Bookmark")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .themedBackdrop()
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
#endif
    }
}
