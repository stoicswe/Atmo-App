import Adwaita
import Foundation
import AtmoCore

/// The Library panes: Bookmarks (with folders), Liked, Drafts, Ghosts.
extension MainView {

    // MARK: - Bookmarks

    struct BookmarkRowSnapshot: Identifiable, Equatable {
        let id: String
        let authorDID: String
        let author: String
        let handle: String
        let avatarURL: URL?
        let text: String
        let time: String
        let folderID: String?
    }

    struct FolderRowSnapshot: Identifiable, Equatable {
        let id: String
        let name: String
        let count: Int
    }

    var bookmarkFolders: [FolderRowSnapshot] {
        _ = tick
        return onMain {
            let state = BookmarkFolderStore.shared.state
            let all = BookmarkStore.shared.bookmarks
            return state.sortedFolders.map {
                FolderRowSnapshot(id: $0.id.uuidString, name: $0.name, count: state.count(in: $0.id, from: all))
            }
        }
    }

    var bookmarkRows: [BookmarkRowSnapshot] {
        _ = tick
        return onMain {
            let state = BookmarkFolderStore.shared.state
            let folderID = bookmarkFolderID.flatMap(UUID.init(uuidString:))
            return state.bookmarks(in: folderID, from: BookmarkStore.shared.bookmarks).map { bookmark in
                BookmarkRowSnapshot(
                    id: bookmark.uri,
                    authorDID: bookmark.authorDID,
                    author: bookmark.authorDisplayName ?? bookmark.authorHandle,
                    handle: bookmark.authorHandle,
                    avatarURL: bookmark.authorAvatarURL,
                    text: bookmark.text,
                    time: bookmark.indexedAt.atmoFormatted(),
                    folderID: state.folderID(forBookmarkURI: bookmark.uri)?.uuidString
                )
            }
        }
    }

    var bookmarkPaneTitle: String {
        if let id = bookmarkFolderID, let folder = bookmarkFolders.first(where: { $0.id == id }) {
            return folder.name
        }
        return "Bookmarks"
    }

    @ViewBuilder var bookmarksHeaderActions: Body {
        if bookmarkFolderID != nil {
            Button(icon: .custom(name: "go-previous-symbolic")) { bookmarkFolderID = nil }
                .tooltip("All bookmarks")
                .flat()
            Button(icon: .custom(name: "document-edit-symbolic")) { beginRenameFolder() }
                .tooltip("Rename folder")
                .flat()
            Button(icon: .custom(name: "user-trash-symbolic")) { folderDeleteID = bookmarkFolderID }
                .tooltip("Delete folder")
                .flat()
        } else {
            Button(icon: .custom(name: "folder-new-symbolic")) {
                folderRenameID = nil
                folderNameInput = ""
                folderDialogVisible = true
            }
            .tooltip("New folder")
            .flat()
        }
    }

    @ViewBuilder var bookmarksPane: Body {
        let folders = bookmarkFolderID == nil ? bookmarkFolders : []
        let rows = bookmarkRows
        if folders.isEmpty && rows.isEmpty {
            StatusPage(
                bookmarkFolderID == nil ? "No bookmarks yet" : "Empty folder",
                icon: .custom(name: "user-bookmarks-symbolic"),
                description: bookmarkFolderID == nil
                    ? "Use the bookmark button under a post to save it here."
                    : "Move bookmarks here from their ··· menu."
            )
            .vexpand()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(folders, id: \.id) { folder in
                        HStack(spacing: 10) {
                            Symbol(icon: .custom(name: "folder-symbolic"))
                                .style("accent")
                            Text(folder.name)
                                .ellipsize()
                                .style("heading")
                                .halign(.start)
                                .hexpand()
                            Text("\(folder.count)")
                                .style("dim-label")
                            Symbol(icon: .custom(name: "go-next-symbolic"))
                                .style("dim-label")
                        }
                        .padding(10)
                        .onClick { bookmarkFolderID = folder.id }
                        Separator()
                    }
                    ForEach(rows, id: \.id) { row in
                        bookmarkRow(row)
                        Separator()
                    }
                }
                .frame(maxWidth: 720)
            }
            .vexpand()
        }
    }

    @ViewBuilder func bookmarkRow(_ row: BookmarkRowSnapshot) -> Body {
        HStack(spacing: 10) {
            remoteAvatar(url: row.avatarURL, name: row.author, size: 36)
                .valign(.start)
                .onClick { openProfile(actor: row.authorDID) }
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.author)
                        .ellipsize()
                        .style("heading")
                        .halign(.start)
                    Text("@\(row.handle)")
                        .ellipsize()
                        .style("dim-label")
                        .halign(.start)
                        .hexpand()
                    Text(row.time)
                        .style("dim-label")
                        .style("caption")
                }
                Text(row.text.isEmpty ? "(media only)" : row.text)
                    .wrap()
                    .lines(4)
                    .ellipsize()
                    .xalign(0)
                    .halign(.start)
            }
            .hexpand()
            .onClick { openThread(uri: row.id) }
            VStack(spacing: 2) {
                Button(icon: .custom(name: "view-more-symbolic")) { moreMenuURI = "bookmark:" + row.id }
                    .flat()
                    .tooltip("Move or remove")
                    .popover(visible: moreMenuBinding("bookmark:" + row.id)) {
                        bookmarkMenu(row)
                    }
            }
            .valign(.start)
        }
        .padding(10)
    }

    @ViewBuilder func bookmarkMenu(_ row: BookmarkRowSnapshot) -> Body {
        let folders = bookmarkFolders
        VStack(spacing: 4) {
            Button("Open Thread", icon: .custom(name: "atmo-thread-symbolic")) {
                moreMenuURI = nil
                openThread(uri: row.id)
            }
            .flat()
            .halign(.start)
            if row.folderID != nil {
                Button("Move out of folder", icon: .custom(name: "folder-symbolic")) {
                    moreMenuURI = nil
                    onMain { BookmarkFolderStore.shared.move(bookmarkURI: row.id, to: nil) }
                    tick += 1
                }
                .flat()
                .halign(.start)
            }
            ForEach(folders.filter { $0.id != row.folderID }, id: \.id) { folder in
                Button("Move to \(folder.name)", icon: .custom(name: "folder-symbolic")) {
                    moreMenuURI = nil
                    onMain { BookmarkFolderStore.shared.move(bookmarkURI: row.id, to: UUID(uuidString: folder.id)) }
                    tick += 1
                }
                .flat()
                .halign(.start)
            }
            Button("Remove Bookmark", icon: .custom(name: "user-trash-symbolic")) {
                moreMenuURI = nil
                onMain { BookmarkStore.shared.remove(uri: row.id) }
                showToast("Bookmark removed")
                tick += 1
            }
            .flat()
            .halign(.start)
            .style("error")
        }
        .padding(6)
    }

    func beginRenameFolder() {
        guard let id = bookmarkFolderID else { return }
        folderRenameID = id
        folderNameInput = bookmarkFolders.first { $0.id == id }?.name ?? ""
        folderDialogVisible = true
    }

    @ViewBuilder var folderDialogContent: Body {
        VStack(spacing: 12) {
            Entry("Folder name", text: $folderNameInput)
                .activate { commitFolderDialog() }
            HStack(spacing: 8) {
                Text("")
                    .hexpand()
                Button("Cancel") { folderDialogVisible = false }
                Button(folderRenameID == nil ? "Create" : "Rename") { commitFolderDialog() }
                    .style("suggested-action")
                    .insensitive(folderNameInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    func commitFolderDialog() {
        let name = folderNameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        folderDialogVisible = false
        onMain {
            if let id = folderRenameID.flatMap(UUID.init(uuidString:)) {
                BookmarkFolderStore.shared.renameFolder(id: id, to: name)
            } else {
                _ = BookmarkFolderStore.shared.createFolder(named: name)
            }
        }
        folderRenameID = nil
        tick += 1
    }

    var folderDeleteVisibleBinding: Binding<Bool> {
        Binding(get: { folderDeleteID != nil }, set: { if !$0 { folderDeleteID = nil } })
    }

    func confirmDeleteFolder() {
        guard let id = folderDeleteID.flatMap(UUID.init(uuidString:)) else { return }
        folderDeleteID = nil
        bookmarkFolderID = nil
        onMain { BookmarkFolderStore.shared.deleteFolder(id: id) }
        tick += 1
    }

    // MARK: - Liked

    struct LikedRowSnapshot: Identifiable, Equatable {
        let id: String
        let authorDID: String
        let author: String
        let handle: String
        let avatarURL: URL?
        let text: String
        let time: String
        let likedAt: String
    }

    var likedRows: [LikedRowSnapshot] {
        _ = tick
        return onMain {
            LikedPostsStore.shared.likedPosts.map {
                LikedRowSnapshot(
                    id: $0.uri,
                    authorDID: $0.authorDID,
                    author: $0.authorDisplayName ?? $0.authorHandle,
                    handle: $0.authorHandle,
                    avatarURL: $0.authorAvatarURL,
                    text: $0.text,
                    time: $0.indexedAt.atmoFormatted(),
                    likedAt: $0.likedAt.atmoFormatted()
                )
            }
        }
    }

    var likedIsBackfilling: Bool {
        _ = tick
        return onMain { LikedPostsStore.shared.isBackfilling }
    }

    @ViewBuilder var likedPane: Body {
        let rows = likedRows
        VStack(spacing: 0) {
            Banner("Syncing past likes…", visible: likedIsBackfilling)
            if rows.isEmpty {
                StatusPage(
                    "No liked posts yet",
                    icon: .custom(name: "atmo-heart-filled-symbolic"),
                    description: "Posts you like will collect here so you can look back on them."
                )
                .vexpand()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.id) { row in
                            HStack(spacing: 10) {
                                remoteAvatar(url: row.avatarURL, name: row.author, size: 36)
                                    .valign(.start)
                                    .onClick { openProfile(actor: row.authorDID) }
                                VStack(spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(row.author)
                                            .ellipsize()
                                            .style("heading")
                                            .halign(.start)
                                        Text("@\(row.handle)")
                                            .ellipsize()
                                            .style("dim-label")
                                            .halign(.start)
                                            .hexpand()
                                        Text(row.time)
                                            .style("dim-label")
                                            .style("caption")
                                    }
                                    Text(row.text.isEmpty ? "(media only)" : row.text)
                                        .wrap()
                                        .lines(4)
                                        .ellipsize()
                                        .xalign(0)
                                        .halign(.start)
                                    Text("Liked \(row.likedAt)")
                                        .style("caption")
                                        .style("dim-label")
                                        .halign(.start)
                                }
                                .hexpand()
                                .onClick { openThread(uri: row.id) }
                                Button(icon: .custom(name: "user-trash-symbolic")) {
                                    onMain { LikedPostsStore.shared.remove(uri: row.id) }
                                    tick += 1
                                }
                                .flat()
                                .tooltip("Forget this like")
                                .valign(.start)
                            }
                            .padding(10)
                            Separator()
                        }
                    }
                    .frame(maxWidth: 720)
                }
                .vexpand()
            }
        }
    }

    // MARK: - Drafts

    struct DraftRowSnapshot: Identifiable, Equatable {
        let id: String
        let preview: String
        let context: String
        let modified: String
    }

    var draftRows: [DraftRowSnapshot] {
        _ = tick
        return onMain {
            DraftStore.shared.drafts.map { draft in
                let first = draft.posts.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let media = draft.posts.contains { $0.hasMedia }
                var context: [String] = []
                if draft.replyToURI != nil { context.append("Reply") }
                if draft.quotedPostURI != nil { context.append("Quote") }
                if draft.posts.count > 1 { context.append("Thread · \(draft.posts.count) posts") }
                if media { context.append("Media") }
                return DraftRowSnapshot(
                    id: draft.id.uuidString,
                    preview: first.isEmpty ? (media ? "(media only)" : "(empty)") : first,
                    context: context.isEmpty ? "Draft" : context.joined(separator: " · "),
                    modified: draft.modifiedAt.atmoFormatted()
                )
            }
        }
    }

    @ViewBuilder var draftsPane: Body {
        let rows = draftRows
        if rows.isEmpty {
            StatusPage(
                "No drafts",
                icon: .custom(name: "document-edit-symbolic"),
                description: "Posts you start but don't send will be saved here."
            )
            .vexpand()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.id) { row in
                        HStack(spacing: 10) {
                            VStack(spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(row.context)
                                        .style("caption-heading")
                                        .style("dim-label")
                                        .halign(.start)
                                        .hexpand()
                                    Text(row.modified)
                                        .style("dim-label")
                                        .style("caption")
                                }
                                Text(row.preview)
                                    .wrap()
                                    .lines(3)
                                    .ellipsize()
                                    .xalign(0)
                                    .halign(.start)
                            }
                            .hexpand()
                            .onClick { resumeDraft(id: row.id) }
                            Button(icon: .custom(name: "user-trash-symbolic")) {
                                onMain {
                                    if let id = UUID(uuidString: row.id) { DraftStore.shared.delete(id: id) }
                                }
                                tick += 1
                            }
                            .flat()
                            .tooltip("Delete draft")
                            .valign(.start)
                        }
                        .padding(10)
                        Separator()
                    }
                }
                .frame(maxWidth: 720)
            }
            .vexpand()
        }
    }

    func resumeDraft(id: String) {
        guard let draft = onMain({ DraftStore.shared.drafts.first { $0.id.uuidString == id } }) else { return }
        openComposer(draft: draft)
    }

    // MARK: - Ghosts

    struct GhostRowSnapshot: Identifiable, Equatable {
        let id: String
        let text: String
        let created: String
        let footer: String
        let isActive: Bool
    }

    var ghostRows: (active: [GhostRowSnapshot], archive: [GhostRowSnapshot]) {
        _ = tick
        return onMain {
            let now = Date()
            let active = GhostPostStore.shared.active.map {
                GhostRowSnapshot(
                    id: $0.uri, text: $0.text, created: $0.createdAt.atmoFormatted(),
                    footer: GhostPostPolicy.remainingText(until: $0.expiresAt, now: now), isActive: true
                )
            }
            let archive = GhostPostStore.shared.archive.map {
                GhostRowSnapshot(
                    id: $0.uri, text: $0.text, created: $0.createdAt.atmoFormatted(),
                    footer: "Ended \(($0.endedAt ?? $0.expiresAt).atmoFormatted())", isActive: false
                )
            }
            return (active, archive)
        }
    }

    @ViewBuilder var ghostsPane: Body {
        let rows = ghostRows
        if rows.active.isEmpty && rows.archive.isEmpty {
            StatusPage(
                "No ghosts",
                icon: .custom(name: "weather-fog-symbolic"),
                description: "Ghosts you post will gather here while they're up, then move to the archive once they end."
            )
            .vexpand()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if !rows.active.isEmpty {
                        sidebarHeader("Active · \(rows.active.count)")
                        ForEach(rows.active, id: \.id) { row in
                            ghostRow(row)
                            Separator()
                        }
                    }
                    if !rows.archive.isEmpty {
                        HStack(spacing: 6) {
                            sidebarHeader("Ended · \(rows.archive.count)")
                            Text("")
                                .hexpand()
                            Button("Clear") {
                                onMain { GhostPostStore.shared.clearArchive() }
                                tick += 1
                            }
                            .flat()
                        }
                        ForEach(rows.archive, id: \.id) { row in
                            ghostRow(row)
                            Separator()
                        }
                    }
                }
                .frame(maxWidth: 720)
            }
            .vexpand()
        }
    }

    @ViewBuilder func ghostRow(_ row: GhostRowSnapshot) -> Body {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(row.text.isEmpty ? "(media only)" : row.text)
                    .wrap()
                    .lines(4)
                    .ellipsize()
                    .xalign(0)
                    .halign(.start)
                HStack(spacing: 6) {
                    Text(row.created)
                        .style("caption")
                        .style("dim-label")
                    Text("·")
                        .style("caption")
                        .style("dim-label")
                    Text(row.footer)
                        .style("caption")
                        .style(row.isActive ? "accent" : "dim-label")
                }
                .halign(.start)
            }
            .hexpand()
            .onClick { if row.isActive { openThread(uri: row.id) } }
            if row.isActive {
                Button("End Now") {
                    runCore { await GhostPostStore.shared.endNow(uri: row.id, service: AppSession.shared.service) }
                }
                .flat()
                .style("error")
                .valign(.start)
            } else {
                Button(icon: .custom(name: "user-trash-symbolic")) {
                    onMain { GhostPostStore.shared.removeFromArchive(uri: row.id) }
                    tick += 1
                }
                .flat()
                .tooltip("Remove from archive")
                .valign(.start)
            }
        }
        .padding(10)
    }
}
