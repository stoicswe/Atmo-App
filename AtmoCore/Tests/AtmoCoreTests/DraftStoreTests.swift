import Foundation
import Testing
@testable import AtmoCore

@MainActor
struct DraftStoreTests {

    private func makeStore() -> DraftStore {
        let suiteName = "atmo-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return DraftStore(defaults: defaults)
    }

    @Test func saveInsertsAndUpserts() {
        let store = makeStore()
        var draft = ComposerDraft(posts: [DraftPost(text: "hello")])
        store.save(draft)
        #expect(store.drafts.count == 1)

        draft.posts[0].text = "hello, world"
        store.save(draft)
        #expect(store.drafts.count == 1)
        #expect(store.drafts[0].posts[0].text == "hello, world")
    }

    @Test func deleteRemovesDraft() {
        let store = makeStore()
        let draft = ComposerDraft(posts: [DraftPost(text: "hello")])
        store.save(draft)
        store.delete(id: draft.id)
        #expect(store.drafts.isEmpty)
    }

    @Test func latestDraftMatchesReplyContext() {
        let store = makeStore()
        let root = ComposerDraft(posts: [DraftPost(text: "a root draft")])
        let reply = ComposerDraft(
            posts: [DraftPost(text: "a reply draft")],
            replyToURI: "at://did:a/app.bsky.feed.post/1"
        )
        store.save(root)
        store.save(reply)

        let foundRoot = store.latestDraft(replyToURI: nil, quotedPostURI: nil)
        #expect(foundRoot?.id == root.id)

        let foundReply = store.latestDraft(
            replyToURI: "at://did:a/app.bsky.feed.post/1",
            quotedPostURI: nil
        )
        #expect(foundReply?.id == reply.id)
    }

    @Test func latestDraftIgnoresEmptyDrafts() {
        let store = makeStore()
        store.save(ComposerDraft(posts: [DraftPost(text: "   ")]))
        #expect(store.latestDraft(replyToURI: nil, quotedPostURI: nil) == nil)
    }
}
