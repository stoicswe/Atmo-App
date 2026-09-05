import SwiftUI
import Combine
import AtmoCore

// MARK: - Vault View
// The private section of Bookmarks. Opened in place of the bookmark list:
//   • Locked: a first-use explanation (once), then Face ID / Touch ID /
//     passcode through the platform seam. Nothing of the contents is
//     rendered until the lock opens.
//   • Unlocked: nested folders opened in place with a breadcrumb, posts
//     filed among them, Move To ▸ across the whole tree, and Move to
//     Bookmarks to send a post back out. Leaving the screen re-locks when
//     the duration is "Every time"; leaving the app always does.
struct VaultView: View {
    let navPath: Binding<NavigationPath>
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    /// The folder open in place; nil = the vault's top level.
    @State private var openFolderID: UUID? = nil
    @State private var showNewFolderAlert = false
    @State private var renameTarget: VaultFolder? = nil
    @State private var deleteTarget: VaultFolder? = nil
    @State private var folderNameInput = ""
    @State private var unlockFailed = false
    /// Ticks so a timed unlock's expiry is noticed without interaction.
    @State private var now = Date()

    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let lock = VaultLock.shared
        Group {
            if lock.isUnlocked {
                unlockedContent
            } else {
                lockedContent(lock: lock)
            }
        }
        .onReceive(clock) { now = $0 }
        .onDisappear { VaultLock.shared.lockOnLeave() }
        .task {
            // Arriving locked with setup done: prompt straight away.
            if !lock.isUnlocked, lock.hasCompletedSetup { await attemptUnlock() }
        }
    }

    // MARK: - Locked

    private func lockedContent(lock: VaultLock) -> some View {
        VStack(spacing: AtmoTheme.Spacing.xl) {
            closeRow

            Spacer(minLength: 0)

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(AtmoColors.accent)
                .symbolEffect(.pulse, isActive: lock.isAuthenticating)

            VStack(spacing: AtmoTheme.Spacing.sm) {
                Text(lock.hasCompletedSetup ? "Vault Locked" : "Set Up Your Vault")
                    .font(.title2.weight(.bold))
                Text(lock.hasCompletedSetup
                     ? "Unlock with Face ID, Touch ID, or your passcode."
                     : "The Vault is a private place for bookmarks. It opens with Face ID, Touch ID, or your passcode, syncs privately through iCloud, and is never indexed for Spotlight or Siri. You'll be asked to allow Face ID or Touch ID the first time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AtmoTheme.Spacing.xxl)
            }

            if unlockFailed {
                Label("Couldn't verify — try again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Haptics.tap()
                Task { await attemptUnlock() }
            } label: {
                HStack {
                    if lock.isAuthenticating {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "faceid")
                        Text(lock.hasCompletedSetup ? "Unlock" : "Continue")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: 280)
                .padding(AtmoTheme.Spacing.md)
                .background(AtmoColors.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.large, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(lock.isAuthenticating || !lock.isAvailable)

            if !lock.isAvailable {
                Text("Set up Face ID, Touch ID, or a passcode on this device to use the Vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AtmoTheme.Spacing.xxl)
            }

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func attemptUnlock() async {
        unlockFailed = false
        let ok = await VaultLock.shared.unlock()
        if ok {
            Haptics.confirm()
        } else {
            unlockFailed = true
        }
    }

    // MARK: - Unlocked

    private var unlockedContent: some View {
        let store = VaultStore.shared
        let state = store.state
        let openFolder = openFolderID.flatMap { state.folder(id: $0) }
        let subfolders = state.children(of: openFolderID)
        let posts = state.posts(in: openFolderID)

        return VStack(spacing: 0) {
            headerBar(openFolder: openFolder, state: state)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if !subfolders.isEmpty {
                        sectionHeader("Folders")
                        ForEach(subfolders) { folder in
                            folderRow(folder, count: state.count(in: folder.id))
                            Divider().overlay(Color.secondary.opacity(0.1))
                        }
                    }
                    if !posts.isEmpty {
                        sectionHeader("Posts")
                        ForEach(posts) { post in
                            BookmarkRowView(bookmark: post)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    navPath.wrappedValue = NavigationPath([PostNavTarget(uri: post.uri)])
                                }
                                .contextMenu { postMenu(for: post, state: state) }
                            Divider().overlay(Color.secondary.opacity(0.1))
                        }
                    }
                    if subfolders.isEmpty, posts.isEmpty {
                        ContentUnavailableView(
                            openFolder == nil ? "Vault Is Empty" : "Empty Folder",
                            systemImage: "lock.open",
                            description: Text(openFolder == nil
                                ? "Use Move to Vault from a bookmark's menu to keep it here privately."
                                : "Use Move To from a post's menu to file it here.")
                        )
                        .padding(.top, AtmoTheme.Spacing.xxl)
                    }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: openFolderID)
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $folderNameInput)
            Button("Create") {
                VaultStore.shared.createFolder(named: folderNameInput, in: openFolderID)
                folderNameInput = ""
            }
            Button("Cancel", role: .cancel) { folderNameInput = "" }
        } message: {
            Text(openFolderID == nil ? "Folders in the Vault sync with iCloud, privately." : "Created inside the open folder.")
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Folder name", text: $folderNameInput)
            Button("Rename") {
                if let target = renameTarget {
                    VaultStore.shared.renameFolder(id: target.id, to: folderNameInput)
                }
                renameTarget = nil
                folderNameInput = ""
            }
            Button("Cancel", role: .cancel) { renameTarget = nil; folderNameInput = "" }
        }
        .alert(
            "Delete \"\(deleteTarget?.name ?? "Folder")\"?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Delete Folder", role: .destructive) {
                if let target = deleteTarget {
                    if let open = openFolderID, VaultStore.shared.state.isSameOrDescendant(open, of: target.id) {
                        openFolderID = target.parentID
                    }
                    VaultStore.shared.deleteFolder(id: target.id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Its subfolders go too; the posts inside move up a level. Nothing leaves the Vault.")
        }
    }

    // MARK: Header — close/back, breadcrumb, new folder, lock

    private func headerBar(openFolder: VaultFolder?, state: VaultState) -> some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            Button {
                if let openFolder {
                    openFolderID = openFolder.parentID
                } else {
                    onClose()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                    Text(openFolder == nil ? "Bookmarks" : (state.folder(id: openFolder!.parentID ?? UUID())?.name ?? "Vault"))
                        .font(.subheadline)
                        .lineLimit(1)
                }
                .foregroundStyle(AtmoColors.accent)
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Image(systemName: "lock.open.fill")
                    .font(.caption)
                    .foregroundStyle(AtmoColors.accent)
                Text(openFolder?.name ?? "Vault")
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let openFolder {
                Menu {
                    Button {
                        folderNameInput = openFolder.name
                        renameTarget = openFolder
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleteTarget = openFolder
                    } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Folder options")
            }

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

            Button {
                Haptics.soft()
                VaultLock.shared.lock()
            } label: {
                Image(systemName: "lock.fill")
                    .foregroundStyle(AtmoColors.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lock Vault")
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.sm)
    }

    private var closeRow: some View {
        HStack {
            Button {
                onClose()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                    Text("Bookmarks")
                        .font(.subheadline)
                }
                .foregroundStyle(AtmoColors.accent)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.sm)
    }

    // MARK: Rows and menus

    private func folderRow(_ folder: VaultFolder, count: Int) -> some View {
        Button {
            openFolderID = folder.id
        } label: {
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
            .padding(.vertical, AtmoTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                folderNameInput = folder.name
                renameTarget = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = folder
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    /// Move To ▸ walks the whole tree (indented by depth); Move to
    /// Bookmarks sends the post back out; Remove drops it.
    @ViewBuilder
    private func postMenu(for post: BookmarkedPost, state: VaultState) -> some View {
        let current = state.folderID(forPostURI: post.uri)
        let tree = state.flattened()
        if current != nil || !tree.isEmpty {
            Menu {
                if current != nil {
                    Button {
                        VaultStore.shared.move(postURI: post.uri, to: nil)
                    } label: {
                        Label("Vault", systemImage: "lock.open")
                    }
                }
                ForEach(tree, id: \.folder.id) { entry in
                    if entry.folder.id != current {
                        Button {
                            VaultStore.shared.move(postURI: post.uri, to: entry.folder.id)
                        } label: {
                            Label(String(repeating: "  ", count: entry.depth) + entry.folder.name, systemImage: "folder")
                        }
                    }
                }
            } label: {
                Label("Move To", systemImage: "folder")
            }
        }
        Button {
            Haptics.confirm()
            withAnimation { VaultStore.shared.moveOutOfVault(uri: post.uri) }
        } label: {
            Label("Move to Bookmarks", systemImage: "bookmark")
        }
        Button(role: .destructive) {
            withAnimation { VaultStore.shared.remove(uri: post.uri) }
        } label: {
            Label("Remove", systemImage: "trash")
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
}
