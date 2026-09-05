import Foundation
import Testing
@testable import AtmoCore

/// Covers the pure value core of bookmark folders (creation, renaming,
/// deletion, filing, pruning, cross-device merge) and the Liked history
/// trim rule.
struct BookmarkFoldersTests {

    @MainActor
    private func bookmark(_ uri: String) -> BookmarkedPost {
        BookmarkedPost(post: PostItem(testURI: uri))
    }

    // MARK: - Folder CRUD

    @Test func createTrimsAndRefusesEmptyNames() {
        var state = BookmarkFolderState()
        #expect(state.createFolder(named: "   ") == nil)
        let folder = state.createFolder(named: "  Reading List  ")
        #expect(folder?.name == "Reading List")
        #expect(state.folders.count == 1)
    }

    @Test func renameRefusesEmptyAndAppliesTrimmed() {
        var state = BookmarkFolderState()
        let folder = state.createFolder(named: "Recipes")!
        state.renameFolder(id: folder.id, to: "   ")
        #expect(state.folder(id: folder.id)?.name == "Recipes")
        state.renameFolder(id: folder.id, to: " Dinner Ideas ")
        #expect(state.folder(id: folder.id)?.name == "Dinner Ideas")
    }

    @Test func sortedFoldersIsCaseInsensitiveAlphabetical() {
        var state = BookmarkFolderState()
        state.createFolder(named: "zebra")
        state.createFolder(named: "Apple")
        state.createFolder(named: "mango")
        #expect(state.sortedFolders.map(\.name) == ["Apple", "mango", "zebra"])
    }

    // MARK: - Filing

    @MainActor
    @Test func moveFilesAndUnfilesAndGuardsUnknownFolders() {
        var state = BookmarkFolderState()
        let folder = state.createFolder(named: "Swift")!
        state.move(bookmarkURI: "at://a", to: folder.id)
        #expect(state.folderID(forBookmarkURI: "at://a") == folder.id)

        // nil → back to top level.
        state.move(bookmarkURI: "at://a", to: nil)
        #expect(state.folderID(forBookmarkURI: "at://a") == nil)

        // Unknown folder id behaves as unfile — never a dangling pointer.
        state.move(bookmarkURI: "at://a", to: UUID())
        #expect(state.folderID(forBookmarkURI: "at://a") == nil)
    }

    @MainActor
    @Test func deleteFolderReturnsContentsToTopLevel() {
        var state = BookmarkFolderState()
        let folder = state.createFolder(named: "Temp")!
        state.move(bookmarkURI: "at://a", to: folder.id)
        state.deleteFolder(id: folder.id)
        #expect(state.folders.isEmpty)
        #expect(state.folderID(forBookmarkURI: "at://a") == nil)
    }

    @MainActor
    @Test func filteringAndCountsFollowAssignments() {
        var state = BookmarkFolderState()
        let folder = state.createFolder(named: "Art")!
        let all = [bookmark("at://a"), bookmark("at://b"), bookmark("at://c")]
        state.move(bookmarkURI: "at://b", to: folder.id)

        #expect(state.bookmarks(in: folder.id, from: all).map(\.uri) == ["at://b"])
        #expect(state.bookmarks(in: nil, from: all).map(\.uri) == ["at://a", "at://c"])
        #expect(state.count(in: folder.id, from: all) == 1)
    }

    @MainActor
    @Test func pruneDropsAssignmentsForRemovedBookmarks() {
        var state = BookmarkFolderState()
        let folder = state.createFolder(named: "Keep")!
        state.move(bookmarkURI: "at://gone", to: folder.id)
        state.move(bookmarkURI: "at://kept", to: folder.id)
        state.pruneAssignments(keeping: ["at://kept"])
        #expect(state.assignments.count == 1)
        #expect(state.folderID(forBookmarkURI: "at://kept") == folder.id)
    }

    // MARK: - Merge

    @Test func mergeKeepsLocalNamesAdoptsSyncedFoldersAndDropsOrphans() {
        var local = BookmarkFolderState()
        let shared = local.createFolder(named: "Local Name")!
        local.move(bookmarkURI: "at://a", to: shared.id)

        var synced = BookmarkFolderState(
            folders: [BookmarkFolder(id: shared.id, name: "Synced Name", createdAt: shared.createdAt)]
        )
        let syncedOnly = synced.createFolder(named: "From Other Device")!
        synced.move(bookmarkURI: "at://b", to: syncedOnly.id)
        // Synced also carries an assignment to a folder nobody has anymore.
        synced.assignments["at://orphan"] = UUID()

        let merged = BookmarkFolderState.merged(local: local, synced: synced)
        #expect(merged.folder(id: shared.id)?.name == "Local Name")
        #expect(merged.folders.count == 2)
        #expect(merged.folderID(forBookmarkURI: "at://a") == shared.id)
        #expect(merged.folderID(forBookmarkURI: "at://b") == syncedOnly.id)
        #expect(merged.folderID(forBookmarkURI: "at://orphan") == nil)
    }

    @Test func codableRoundtripPreservesState() throws {
        // Whole-second date: ISO-8601 encoding drops fractional seconds,
        // so a Date() fixture would differ after the roundtrip.
        let folder = BookmarkFolder(name: "Round Trip", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        var state = BookmarkFolderState(folders: [folder])
        state.move(bookmarkURI: "at://a", to: folder.id)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let revived = try decoder.decode(BookmarkFolderState.self, from: encoder.encode(state))
        #expect(revived == state)
    }

    // MARK: - Liked history rules

    @MainActor
    @Test func likedHistoryCollectsPostsButNotReplies() {
        let topLevel = PostItem(testURI: "at://post")
        let reply = PostItem(testURI: "at://reply", replyParentURI: "at://post")
        #expect(LikedPostsStore.shouldRecord(topLevel))
        #expect(!LikedPostsStore.shouldRecord(reply))
    }

    @MainActor
    @Test func retentionPrunesExpiredEntriesButNeverKeepsAll() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let fresh = LikedPost(
            post: PostItem(testURI: "at://fresh"),
            likedAt: now.addingTimeInterval(-1 * 86_400)
        )
        let stale = LikedPost(
            post: PostItem(testURI: "at://stale"),
            likedAt: now.addingTimeInterval(-20 * 86_400)
        )

        let pruned = LikedPostsStore.pruned([fresh, stale], retention: .days14, now: now)
        #expect(pruned.map(\.uri) == ["at://fresh"])

        let kept = LikedPostsStore.pruned([fresh, stale], retention: .never, now: now)
        #expect(kept.count == 2)
    }

    // MARK: - Liked history cloud merge

    @MainActor
    private func liked(_ uri: String, at likedAt: Date) -> LikedPost {
        LikedPost(post: PostItem(testURI: uri), likedAt: likedAt)
    }

    @MainActor
    @Test func cloudMergeUnionsByURIKeepingNewestLike() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let deviceA = LikedPostsStore.Payload(
            posts: [liked("at://x", at: base), liked("at://a", at: base.addingTimeInterval(10))],
            removed: [:]
        )
        let deviceB = LikedPostsStore.Payload(
            posts: [liked("at://x", at: base.addingTimeInterval(50)), liked("at://b", at: base)],
            removed: [:]
        )
        let merged = LikedPostsStore.mergedPayload([deviceA, deviceB], retention: .never, now: base.addingTimeInterval(100))
        #expect(merged.posts.count == 3)
        #expect(merged.posts.first(where: { $0.uri == "at://x" })?.likedAt == base.addingTimeInterval(50))
    }

    @MainActor
    @Test func cloudMergeRemovalTombstoneBeatsOlderLikeButLosesToRelike() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        // Device A removed both entries at t+20.
        let deviceA = LikedPostsStore.Payload(
            posts: [],
            removed: ["at://gone": base.addingTimeInterval(20), "at://back": base.addingTimeInterval(20)]
        )
        // Device B still carries the old like of "gone" (t+0) and a
        // RE-like of "back" from after the removal (t+40).
        let deviceB = LikedPostsStore.Payload(
            posts: [liked("at://gone", at: base), liked("at://back", at: base.addingTimeInterval(40))],
            removed: [:]
        )
        let merged = LikedPostsStore.mergedPayload([deviceA, deviceB], retention: .never, now: base.addingTimeInterval(100))
        #expect(merged.posts.map(\.uri) == ["at://back"])
        // The beaten tombstone retires; the standing one survives.
        #expect(merged.removed?.keys.contains("at://gone") == true)
        #expect(merged.removed?.keys.contains("at://back") != true)
    }

    @MainActor
    @Test func likedHistoryKeepsNewestUpToCap() {
        let posts = (0..<(LikedPostsStore.maxEntries + 25)).map { index in
            LikedPost(
                post: PostItem(testURI: "at://like/\(index)"),
                likedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let capped = LikedPostsStore.capped(posts)
        #expect(capped.count == LikedPostsStore.maxEntries)
        // Newest first, oldest dropped.
        #expect(capped.first?.uri == "at://like/\(LikedPostsStore.maxEntries + 24)")
        #expect(!capped.contains { $0.uri == "at://like/0" })
    }
}
