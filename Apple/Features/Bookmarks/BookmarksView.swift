import SwiftUI
import AtmoCore
import UniformTypeIdentifiers

// MARK: - BookmarksView
// The user's iCloud-synced bookmarks, organized into folders
// (BookmarkFolderStore — iCloud KVS, so folders sync across devices
// without appearing in iCloud Drive):
//   • Header bar: New Folder, and a list ⇄ grid toggle. Inside a folder
//     it becomes back + folder name + rename/delete menu.
//   • List mode: folder rows with counts, then the bookmarks.
//   • Grid mode: folders as Liquid Glass "stacks" wearing their count,
//     bookmarks as post cards.
//   • Bookmarks drag onto folders (rows or stacks) to file them; the
//     context menu offers Move To / Remove for non-drag flows.
//   • Folders open in place (no nav push), so the view works identically
//     inside the split-view detail column and the iPhone stack.
struct BookmarksView: View {

    /// When non-nil (iPad/macOS split view), navigation uses the shared parent
    /// NavigationStack in AppNavigation. When nil (iPhone), owns its own stack.
    var splitNavPath: Binding<NavigationPath>? = nil
    @State private var ownedNavPath = NavigationPath()

    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    // MARK: View state

    private enum ViewMode: String { case list, grid }

    @AppStorage("atmo.bookmarks.viewMode") private var viewModeRaw: String = ViewMode.list.rawValue
    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .list }

    /// The folder currently opened in place; nil = top level.
    @State private var openFolderID: UUID? = nil

    // Folder management dialogs
    @State private var showNewFolderAlert = false
    @State private var renameTarget: BookmarkFolder? = nil
    @State private var deleteTarget: BookmarkFolder? = nil
    @State private var folderNameInput = ""

    var body: some View {
        if splitNavPath != nil {
            bookmarksContent
        } else {
            NavigationStack(path: $ownedNavPath) {
                bookmarksContent
                    .navigationTitle("Bookmarks")
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
    private var bookmarksContent: some View {
        let store = BookmarkStore.shared
        let state = BookmarkFolderStore.shared.state
        let openFolder = openFolderID.flatMap { state.folder(id: $0) }
        // Top level shows the unfiled bookmarks; a folder shows its own.
        let visible = state.bookmarks(in: openFolder?.id, from: store.bookmarks)

        VStack(spacing: 0) {
            headerBar(openFolder: openFolder)
            Divider().overlay(Color.secondary.opacity(0.1))

            if openFolder == nil && store.bookmarks.isEmpty && state.folders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    if viewMode == .grid {
                        gridContent(openFolder: openFolder, visible: visible, state: state, all: store.bookmarks)
                    } else {
                        listContent(openFolder: openFolder, visible: visible, state: state, all: store.bookmarks)
                    }
                }
            }
        }
        // Assignments for bookmarks that were removed elsewhere get
        // dropped whenever the set changes (no-op persist when clean).
        .task(id: store.bookmarks.count) {
            BookmarkFolderStore.shared.pruneAssignments(keeping: Set(store.bookmarks.map(\.uri)))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: openFolderID)
        // ── Folder management dialogs ──
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $folderNameInput)
            Button("Create") {
                BookmarkFolderStore.shared.createFolder(named: folderNameInput)
                folderNameInput = ""
            }
            Button("Cancel", role: .cancel) { folderNameInput = "" }
        } message: {
            Text("Folders organize your bookmarks and sync with iCloud.")
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Folder name", text: $folderNameInput)
            Button("Rename") {
                if let target = renameTarget {
                    BookmarkFolderStore.shared.renameFolder(id: target.id, to: folderNameInput)
                }
                folderNameInput = ""
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) {
                folderNameInput = ""
                renameTarget = nil
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteTarget?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let target = deleteTarget {
                    if openFolderID == target.id { openFolderID = nil }
                    BookmarkFolderStore.shared.deleteFolder(id: target.id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Its bookmarks move back to the top level. Nothing is unsaved.")
        }
    }

    // MARK: - Header bar
    // Lives in content (not the toolbar): in the split view every tab
    // stays mounted, and inactive views' toolbars would bleed onto the
    // shared navigation bar.

    @ViewBuilder
    private func headerBar(openFolder: BookmarkFolder?) -> some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            if let folder = openFolder {
                Button {
                    openFolderID = nil
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                        Text("All")
                            .font(.subheadline)
                    }
                    .foregroundStyle(AtmoColors.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to all bookmarks")

                Text(folder.name)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Menu {
                    Button {
                        beginRename(folder)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleteTarget = folder
                    } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Folder options")
            } else {
                Button {
                    Haptics.tap()
                    folderNameInput = ""
                    showNewFolderAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(AtmoColors.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New folder")

                Spacer(minLength: 0)
            }

            Picker("View", selection: $viewModeRaw) {
                Image(systemName: "list.bullet").tag(ViewMode.list.rawValue)
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
            .accessibilityLabel("List or grid view")
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.sm)
    }

    private func beginRename(_ folder: BookmarkFolder) {
        folderNameInput = folder.name
        renameTarget = folder
    }

    // MARK: - List mode

    @ViewBuilder
    private func listContent(
        openFolder: BookmarkFolder?,
        visible: [BookmarkedPost],
        state: BookmarkFolderState,
        all: [BookmarkedPost]
    ) -> some View {
        LazyVStack(spacing: 0) {
            if openFolder == nil, !state.folders.isEmpty {
                sectionHeader("Folders")
                ForEach(state.sortedFolders) { folder in
                    FolderListRow(
                        folder: folder,
                        count: state.count(in: folder.id, from: all),
                        onOpen: { openFolderID = folder.id },
                        onRename: { beginRename(folder) },
                        onDelete: { deleteTarget = folder },
                        onDropURIs: { file($0, into: folder.id) }
                    )
                    Divider().overlay(Color.secondary.opacity(0.1))
                }
                if !visible.isEmpty {
                    sectionHeader("Saved")
                }
            }

            if visible.isEmpty {
                folderEmptyNote(openFolder: openFolder)
            }

            ForEach(visible) { bookmark in
                BookmarkRowView(bookmark: bookmark)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navPath.wrappedValue = NavigationPath([PostNavTarget(uri: bookmark.uri)])
                    }
                    .draggable(bookmark.uri)
                    .contextMenu { bookmarkMenu(for: bookmark, state: state) }
                Divider().overlay(Color.secondary.opacity(0.1))
            }
        }
    }

    // MARK: - Grid mode

    @ViewBuilder
    private func gridContent(
        openFolder: BookmarkFolder?,
        visible: [BookmarkedPost],
        state: BookmarkFolderState,
        all: [BookmarkedPost]
    ) -> some View {
        let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: AtmoTheme.Spacing.md)]
        LazyVGrid(columns: columns, spacing: AtmoTheme.Spacing.md) {
            if openFolder == nil {
                ForEach(state.sortedFolders) { folder in
                    FolderGridCard(
                        folder: folder,
                        count: state.count(in: folder.id, from: all),
                        onOpen: { openFolderID = folder.id },
                        onRename: { beginRename(folder) },
                        onDelete: { deleteTarget = folder },
                        onDropURIs: { file($0, into: folder.id) }
                    )
                }
            }

            ForEach(visible) { bookmark in
                BookmarkGridCard(bookmark: bookmark)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navPath.wrappedValue = NavigationPath([PostNavTarget(uri: bookmark.uri)])
                    }
                    .draggable(bookmark.uri)
                    .contextMenu { bookmarkMenu(for: bookmark, state: state) }
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.md)

        if visible.isEmpty {
            folderEmptyNote(openFolder: openFolder)
        }
    }

    // MARK: - Shared pieces

    /// Files dropped bookmark URIs into a folder — ignoring anything that
    /// isn't actually a bookmark (the drop payload is plain text).
    private func file(_ uris: [String], into folderID: UUID) {
        let known = Set(BookmarkStore.shared.bookmarks.map(\.uri))
        for uri in uris where known.contains(uri) {
            BookmarkFolderStore.shared.move(bookmarkURI: uri, to: folderID)
        }
        Haptics.confirm()
    }

    /// Context menu on a bookmark: Move To ▸ (top level + each folder),
    /// and Remove — the non-drag path to everything drag can do.
    @ViewBuilder
    private func bookmarkMenu(for bookmark: BookmarkedPost, state: BookmarkFolderState) -> some View {
        let currentFolder = state.folderID(forBookmarkURI: bookmark.uri)
        if currentFolder != nil || !state.folders.isEmpty {
            Menu {
                if currentFolder != nil {
                    Button {
                        BookmarkFolderStore.shared.move(bookmarkURI: bookmark.uri, to: nil)
                    } label: {
                        Label("Bookmarks", systemImage: "bookmark")
                    }
                }
                ForEach(state.sortedFolders) { folder in
                    if currentFolder != folder.id {
                        Button {
                            BookmarkFolderStore.shared.move(bookmarkURI: bookmark.uri, to: folder.id)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                }
            } label: {
                Label("Move To", systemImage: "folder")
            }
        }
        Button(role: .destructive) {
            withAnimation {
                let store = BookmarkStore.shared
                if let idx = store.bookmarks.firstIndex(of: bookmark) {
                    store.remove(at: IndexSet(integer: idx))
                }
            }
        } label: {
            Label("Remove Bookmark", systemImage: "bookmark.slash.fill")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
            .padding(.top, AtmoTheme.Spacing.md)
            .padding(.bottom, AtmoTheme.Spacing.xs)
    }

    @ViewBuilder
    private func folderEmptyNote(openFolder: BookmarkFolder?) -> some View {
        if openFolder != nil {
            ContentUnavailableView(
                "Empty Folder",
                systemImage: "folder",
                description: Text("Drag bookmarks here, or use Move To from a bookmark's menu.")
            )
            .padding(.top, AtmoTheme.Spacing.xxl)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Bookmarks",
            systemImage: "bookmark",
            description: Text("Tap the bookmark icon on any post to save it here.")
        )
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Folder List Row
private struct FolderListRow: View {
    let folder: BookmarkFolder
    let count: Int
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onDropURIs: ([String]) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.md) {
            Image(systemName: "folder.fill")
                .foregroundStyle(AtmoColors.accent)
                .frame(width: 28)
            Text(folder.name)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(isTargeted ? AtmoColors.accent.opacity(0.12) : Color.clear)
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) { Label("Delete Folder", systemImage: "trash") }
        }
        .dropDestination(for: String.self) { items, _ in
            onDropURIs(items)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .animation(.easeInOut(duration: 0.12), value: isTargeted)
        .accessibilityLabel("\(folder.name), \(count) bookmarks")
    }
}

// MARK: - Folder Grid Card
// The Liquid Glass "stack": two material sheets peeking out behind a
// glass front card carrying the folder glyph, name, and count.
private struct FolderGridCard: View {
    let folder: BookmarkFolder
    let count: Int
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onDropURIs: ([String]) -> Void

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            // The pile behind the front card.
            RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.large, style: .continuous)
                .fill(.thinMaterial)
                .opacity(0.5)
                .padding(.horizontal, 22)
                .offset(y: -16)
            RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.large, style: .continuous)
                .fill(.thinMaterial)
                .opacity(0.75)
                .padding(.horizontal, 11)
                .offset(y: -8)

            VStack(spacing: AtmoTheme.Spacing.sm) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(AtmoColors.accent)
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(count == 1 ? "1 post" : "\(count) posts")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AtmoTheme.Spacing.xl)
            .glassCard(cornerRadius: AtmoTheme.CornerRadius.large)
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.large, style: .continuous)
                        .strokeBorder(AtmoColors.accent, lineWidth: 2)
                }
            }
        }
        .padding(.top, 16)
        .scaleEffect(isTargeted ? 1.04 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) { Label("Delete Folder", systemImage: "trash") }
        }
        .dropDestination(for: String.self) { items, _ in
            onDropURIs(items)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTargeted)
        .accessibilityLabel("\(folder.name) folder, \(count) posts")
    }
}

// MARK: - Bookmark Grid Card
// A bookmark as a compact post card on the glass content surface.
private struct BookmarkGridCard: View {
    let bookmark: BookmarkedPost

    var body: some View {
        VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {
            HStack(spacing: AtmoTheme.Spacing.xs) {
                AvatarView(url: bookmark.authorAvatarURL, size: 20)
                Text(bookmark.authorDisplayName ?? "@\(bookmark.authorHandle)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            if bookmark.text.isEmpty {
                Text("@\(bookmark.authorHandle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(bookmark.text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                Text(bookmark.bookmarkedAt.atmoFormatted())
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(AtmoTheme.Spacing.md)
        .frame(height: 168, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphicGlassCard()
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
