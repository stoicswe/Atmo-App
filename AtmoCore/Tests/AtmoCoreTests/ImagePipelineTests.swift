import Foundation
import Testing
@testable import AtmoCore

/// CDN preset selection and the enhanced-image cache's tiering: files
/// follow a post between transient, bookmarked, and Vault storage, and
/// Vault copies are withheld while locked and deleted on the way out.
struct ImagePipelineTests {

    @Test func cdnPresetRewrites() {
        let avatar = URL(string: "https://cdn.bsky.app/img/avatar/plain/did:plc:x/bafy@jpeg")!
        #expect(BlueskyCDN.avatarThumbnail(avatar).absoluteString == "https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:x/bafy@jpeg")
        let full = URL(string: "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:x/bafy")!
        let thumb = URL(string: "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:x/bafy")!
        #expect(BlueskyCDN.feedThumbnail(full) == thumb)
        #expect(BlueskyCDN.feedFullsize(thumb) == full)
        // Already the wanted preset, or not the CDN: untouched.
        #expect(BlueskyCDN.feedThumbnail(thumb) == thumb)
        let other = URL(string: "https://example.com/img/avatar/x.png")!
        #expect(BlueskyCDN.avatarThumbnail(other) == other)
        #expect(!BlueskyCDN.isCDNImage(other))
    }

    @Test func blobReferenceFromCDNURL() {
        let url = URL(string: "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:z72i7hdynmk6r22z27h6tvur/bafkreiabc@jpeg")!
        let ref = BlueskyCDN.blobReference(from: url)
        #expect(ref?.did == "did:plc:z72i7hdynmk6r22z27h6tvur")
        #expect(ref?.cid == "bafkreiabc")
        let bare = URL(string: "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:x/bafkreidef")!
        #expect(BlueskyCDN.blobReference(from: bare)?.cid == "bafkreidef")
        #expect(BlueskyCDN.blobReference(from: URL(string: "https://example.com/img/a/plain/did:plc:x/c")!) == nil)
        let blob = BlueskyCDN.blobURL(pdsURL: URL(string: "https://pds.example.com")!, did: "did:plc:x", cid: "bafy")
        #expect(blob?.absoluteString == "https://pds.example.com/xrpc/com.atproto.sync.getBlob?did=did:plc:x&cid=bafy")
    }

    @Test func desiredTierFollowsMembership() {
        #expect(EnhancedImageStore.desiredTier(postURI: nil, bookmarked: ["a"], vaulted: ["a"]) == .transient)
        #expect(EnhancedImageStore.desiredTier(postURI: "a", bookmarked: ["a"], vaulted: []) == .bookmarked)
        #expect(EnhancedImageStore.desiredTier(postURI: "a", bookmarked: [], vaulted: ["a"]) == .vault)
        #expect(EnhancedImageStore.desiredTier(postURI: "a", bookmarked: ["a"], vaulted: ["a"]) == .vault)
        #expect(EnhancedImageStore.desiredTier(postURI: "b", bookmarked: ["a"], vaulted: ["a"]) == .transient)
        #expect(EnhancedImageStore.fileName(for: URL(string: "https://x/1")!) == EnhancedImageStore.fileName(for: URL(string: "https://x/1")!))
        #expect(EnhancedImageStore.fileName(for: URL(string: "https://x/1")!) != EnhancedImageStore.fileName(for: URL(string: "https://x/2")!))
    }

    @Test @MainActor func filesFollowThePostBetweenTiers() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("enhanced-\(UUID().uuidString)")
        let store = EnhancedImageStore(
            persistentRoot: base.appendingPathComponent("support"),
            transientRoot: base.appendingPathComponent("caches")
        )
        let image = URL(string: "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:x/bafy")!
        let data = Data("jpeg-bytes".utf8)

        // Enhanced before bookmarking: transient.
        store.store(data, for: image, postURI: "at://post/1", bookmarked: [], vaulted: [])
        #expect(store.tier(for: image) == .transient)
        #expect(store.fileURL(for: image, vaultUnlocked: false) != nil)

        // Bookmarked: promoted and kept.
        store.reconcile(bookmarked: ["at://post/1"], vaulted: [])
        #expect(store.tier(for: image) == .bookmarked)
        #expect(try Data(contentsOf: store.fileURL(for: image, vaultUnlocked: false)!) == data)

        // Moved into the Vault: protected tier, withheld while locked.
        store.reconcile(bookmarked: [], vaulted: ["at://post/1"])
        #expect(store.tier(for: image) == .vault)
        #expect(store.fileURL(for: image, vaultUnlocked: false) == nil)
        #expect(store.fileURL(for: image, vaultUnlocked: true) != nil)

        // Back to bookmarks: follows.
        store.reconcile(bookmarked: ["at://post/1"], vaulted: [])
        #expect(store.tier(for: image) == .bookmarked)

        // Into the Vault, then removed entirely: deleted, not cached.
        store.reconcile(bookmarked: [], vaulted: ["at://post/1"])
        store.reconcile(bookmarked: [], vaulted: [])
        #expect(store.tier(for: image) == nil)

        // A bookmark that's dropped keeps a transient copy.
        store.store(data, for: image, postURI: "at://post/2", bookmarked: ["at://post/2"], vaulted: [])
        #expect(store.tier(for: image) == .bookmarked)
        store.reconcile(bookmarked: [], vaulted: [])
        #expect(store.tier(for: image) == .transient)

        // Clear Caches: everything goes, in every tier.
        store.store(data, for: URL(string: "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:x/other")!, postURI: "at://post/3", bookmarked: ["at://post/3"], vaulted: [])
        #expect(store.totalBytes() > 0)
        store.clearAll()
        #expect(store.totalBytes() == 0)
        #expect(store.tier(for: image) == nil)
    }
}


/// The "Member since" fallback chain's pure part: the earliest PLC
/// operation in an audit log.
struct MemberSinceTests {
    @Test func earliestPLCOperation() {
        let log = Data("""
        [
          {"did":"did:plc:x","operation":{},"cid":"a","nullified":false,"createdAt":"2023-04-12T10:15:30.123Z"},
          {"did":"did:plc:x","operation":{},"cid":"b","nullified":false,"createdAt":"2022-11-01T08:00:00Z"},
          {"did":"did:plc:x","operation":{},"cid":"c","nullified":true,"createdAt":"2024-01-01T00:00:00.000Z"}
        ]
        """.utf8)
        let date = MemberSinceResolver.earliestPLCOperation(in: log)
        #expect(date == ISO8601DateFormatter().date(from: "2022-11-01T08:00:00Z"))
        #expect(MemberSinceResolver.earliestPLCOperation(in: Data("{}".utf8)) == nil)
        #expect(MemberSinceResolver.earliestPLCOperation(in: Data("[]".utf8)) == nil)
    }
}
