import Foundation
import Testing
@testable import AtmoCore

/// Covers the notification content snippets: which rows need a subject-post
/// lookup, how fetched texts are injected, and the alert body wording.
struct NotificationSnippetTests {

    // MARK: - unresolvedSubjectURIs

    @Test func onlyLikesAndRepostsWithoutSnippetsNeedResolution() {
        let items = [
            NotificationItem(testURI: "n1", reason: .like, associatedPostURI: "at://me/post/1"),
            NotificationItem(testURI: "n2", reason: .repost, associatedPostURI: "at://me/post/2"),
            // Reply already carries its text — never refetched.
            NotificationItem(testURI: "n3", reason: .reply, associatedPostURI: "at://me/post/1", contentSnippet: "nice one"),
            // Follows have no subject post.
            NotificationItem(testURI: "n4", reason: .follow),
            // Like with no subject URI can't be resolved.
            NotificationItem(testURI: "n5", reason: .like)
        ]
        #expect(NotificationItem.unresolvedSubjectURIs(in: items) == ["at://me/post/1", "at://me/post/2"])
    }

    @Test func subjectURIsAreDeduplicatedInFirstAppearanceOrder() {
        let items = [
            NotificationItem(testURI: "n1", reason: .like, associatedPostURI: "at://me/post/9"),
            NotificationItem(testURI: "n2", reason: .like, associatedPostURI: "at://me/post/9"),
            NotificationItem(testURI: "n3", reason: .repost, associatedPostURI: "at://me/post/3"),
            NotificationItem(testURI: "n4", reason: .like, associatedPostURI: "at://me/post/9")
        ]
        #expect(NotificationItem.unresolvedSubjectURIs(in: items) == ["at://me/post/9", "at://me/post/3"])
    }

    // MARK: - injectingSnippets

    @Test func fetchedTextsFillLikeAndRepostRows() {
        let items = [
            NotificationItem(testURI: "n1", reason: .like, associatedPostURI: "at://me/post/1"),
            NotificationItem(testURI: "n2", reason: .repost, associatedPostURI: "at://me/post/2"),
            NotificationItem(testURI: "n3", reason: .like, associatedPostURI: "at://me/post/404")
        ]
        let result = NotificationItem.injectingSnippets(
            into: items,
            texts: ["at://me/post/1": "hello world", "at://me/post/2": "shipping day"]
        )
        #expect(result[0].contentSnippet == "hello world")
        #expect(result[1].contentSnippet == "shipping day")
        // Unmatched URI (deleted post) stays snippet-less.
        #expect(result[2].contentSnippet == nil)
    }

    @Test func existingReplyTextIsNeverOverwritten() {
        let items = [
            NotificationItem(testURI: "n1", reason: .reply, associatedPostURI: "at://me/post/1", contentSnippet: "the comment text")
        ]
        let result = NotificationItem.injectingSnippets(
            into: items,
            texts: ["at://me/post/1": "the parent post text"]
        )
        #expect(result[0].contentSnippet == "the comment text")
    }

    @Test func emptyFetchedTextIsNotInjected() {
        let items = [
            NotificationItem(testURI: "n1", reason: .like, associatedPostURI: "at://me/post/1")
        ]
        let result = NotificationItem.injectingSnippets(into: items, texts: ["at://me/post/1": ""])
        #expect(result[0].contentSnippet == nil)
    }

    // MARK: - Equality (SwiftUI diffing)

    @Test func snippetChangeMakesItemsUnequalSoRowsRerender() {
        let bare = NotificationItem(testURI: "n1", reason: .like, associatedPostURI: "at://me/post/1")
        let filled = NotificationItem.injectingSnippets(
            into: [bare],
            texts: ["at://me/post/1": "hello"]
        )[0]
        #expect(bare != filled)
        #expect(bare == NotificationItem(testURI: "n1", reason: .like, associatedPostURI: "at://me/post/1"))
    }

    // MARK: - Newer Bluesky reasons

    @Test func dashedReasonStringsMapToTheirCases() {
        #expect(NotificationItem.NotificationReason(rawValue: "subscribed-post") == .subscribedPost)
        #expect(NotificationItem.NotificationReason(rawValue: "like-via-repost") == .likeViaRepost)
        #expect(NotificationItem.NotificationReason(rawValue: "repost-via-repost") == .repostViaRepost)
        #expect(NotificationItem.NotificationReason(rawValue: "starterpack-joined") == .starterpackJoined)
        #expect(NotificationItem.NotificationReason(rawValue: "verified") == .verified)
        // Anything else still lands on the .unknown fallback in the init.
        #expect(NotificationItem.NotificationReason(rawValue: "some-future-reason") == nil)
    }

    @Test func viaRepostReasonsResolveTheirSubjectPosts() {
        let items = [
            NotificationItem(testURI: "n1", reason: .likeViaRepost, associatedPostURI: "at://me/post/1"),
            NotificationItem(testURI: "n2", reason: .repostViaRepost, associatedPostURI: "at://me/post/2")
        ]
        #expect(NotificationItem.unresolvedSubjectURIs(in: items) == ["at://me/post/1", "at://me/post/2"])
        let result = NotificationItem.injectingSnippets(
            into: items,
            texts: ["at://me/post/1": "my reposted gem", "at://me/post/2": "another one"]
        )
        #expect(result[0].contentSnippet == "my reposted gem")
        #expect(result[1].contentSnippet == "another one")
    }

    @Test func subscribedPostFallbackTargetsOnlySnippetlessRows() {
        let items = [
            // Record carried the text — no fallback needed.
            NotificationItem(testURI: "n1", reason: .subscribedPost, authorHandle: "eff.org", contentSnippet: "we posted this"),
            // Record came back empty — needs the latest-post fetch.
            NotificationItem(testURI: "n2", reason: .subscribedPost, authorHandle: "quiet.bsky.social"),
            NotificationItem(testURI: "n3", reason: .subscribedPost, authorHandle: "quiet.bsky.social"),
            // Other reasons never use the author fallback.
            NotificationItem(testURI: "n4", reason: .like, associatedPostURI: "at://me/post/1")
        ]
        #expect(NotificationItem.subscribedAuthorsNeedingLatestPost(in: items) == ["did:test:quiet.bsky.social"])

        let result = NotificationItem.injectingLatestPosts(
            into: items,
            textsByAuthor: ["did:test:quiet.bsky.social": "their newest post"]
        )
        #expect(result[0].contentSnippet == "we posted this")
        #expect(result[1].contentSnippet == "their newest post")
        #expect(result[2].contentSnippet == "their newest post")
        #expect(result[3].contentSnippet == nil)
    }

    @Test func viaRepostAlertsFollowTheirBaseKindsToggle() {
        #expect(NotificationItem.NotificationReason.likeViaRepost.settingsKind == .like)
        #expect(NotificationItem.NotificationReason.repostViaRepost.settingsKind == .repost)
        #expect(NotificationItem.NotificationReason.reply.settingsKind == .reply)
    }

    @Test func likesAndRepostsPillsIncludeViaRepostVariants() {
        #expect(ActivityCategory.likes.reasons == [.like, .likeViaRepost])
        #expect(ActivityCategory.reposts.reasons == [.repost, .repostViaRepost])
        #expect(ActivityCategory.notifications.reasons == nil)
    }

    // MARK: - Alert body

    @Test func alertBodyIncludesSnippetWhenPresent() {
        #expect(BackgroundSyncEngine.alertBody(for: .like, snippet: "my great post") == "Liked your post: “my great post”")
        #expect(BackgroundSyncEngine.alertBody(for: .reply, snippet: "totally agree") == "Replied to your post: “totally agree”")
    }

    @Test func alertBodyFallsBackToPlainActionWithoutSnippet() {
        #expect(BackgroundSyncEngine.alertBody(for: .like, snippet: nil) == "Liked your post")
        #expect(BackgroundSyncEngine.alertBody(for: .follow, snippet: "   ") == "Followed you")
    }

    @Test func alertBodyFlattensNewlinesAndCapsLength() {
        let body = BackgroundSyncEngine.alertBody(for: .quote, snippet: "line one\nline two")
        #expect(body == "Quoted your post: “line one line two”")

        let long = String(repeating: "x", count: 300)
        let capped = BackgroundSyncEngine.alertBody(for: .like, snippet: long)
        #expect(capped.count < 140)
    }
}
