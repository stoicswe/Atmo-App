import Foundation
import Testing
import ATProtoKit
@testable import AtmoCore

/// Covers sharing a post into chat: the wire message built for a DM
/// (text and/or a record embed), the per-recipient send gating, and the
/// timeline's ability to like/repost a post it only holds as thread
/// context above another post.
struct SendPostTests {

    // MARK: Message input

    @Test func postTravelsAsRecordEmbed() throws {
        let post = PostItem(testURI: "at://did:plc:a/app.bsky.feed.post/1")
        let input = try #require(ConversationDetailViewModel.messageInput(text: "", embeddedPost: post))
        #expect(input.text == "")
        guard case .record(let record) = try #require(input.embed) else {
            Issue.record("expected a record embed")
            return
        }
        #expect(record.record.recordURI == post.uri)
        #expect(record.record.recordCID == post.cid)
    }

    @Test func textOnlyIsTrimmedAndUnembedded() throws {
        let input = try #require(ConversationDetailViewModel.messageInput(text: "  hi there \n", embeddedPost: nil))
        #expect(input.text == "hi there")
        #expect(input.embed == nil)
    }

    @Test func postByReferenceEmbedsAndRejectsBlankReference() throws {
        let input = try #require(ConversationDetailViewModel.messageInput(text: "", postURI: "at://x/app.bsky.feed.post/1", postCID: "bafy"))
        guard case .record(let record) = try #require(input.embed) else {
            Issue.record("expected a record embed")
            return
        }
        #expect(record.record.recordURI == "at://x/app.bsky.feed.post/1")
        #expect(ConversationDetailViewModel.messageInput(text: "", postURI: "", postCID: "bafy") == nil)
        #expect(ConversationDetailViewModel.messageInput(text: "hi", postURI: nil, postCID: nil)?.embed == nil)
    }

    @Test func chatCapabilitiesReflectTheLexicon() {
        // chat.bsky.convo.defs#messageInput embeds: record and join link only.
        #expect(!ChatCapabilities.supportsMedia)
        #expect(ChatCapabilities.supportsPostEmbeds)
        #expect(ChatCapabilities.supportsGIFLinks)
    }

    @Test func nothingToSendIsNil() {
        #expect(ConversationDetailViewModel.messageInput(text: "   ", embeddedPost: nil) == nil)
    }

    // MARK: Send gating and previews

    @Test func sendGating() {
        #expect(SendPostViewModel.canStart(.idle))
        #expect(SendPostViewModel.canStart(.failed))
        #expect(!SendPostViewModel.canStart(.sending))
        #expect(!SendPostViewModel.canStart(.sent))
    }

    @Test func embedOnlyMessagePreview() {
        #expect(MessageItem.previewText(text: "", hasEmbed: true) == "Shared a post")
        #expect(MessageItem.previewText(text: "look", hasEmbed: true) == "look")
        #expect(MessageItem.previewText(text: "", hasEmbed: false) == "")
        #expect(MessageItem.postURI(in: nil) == nil)
        let plain = MessageItem(testID: "m1", senderDID: "did:plc:x", text: "hi", sentAt: Date())
        #expect(plain.embeddedRecord == nil)
        #expect(plain.embeddedPostURI == nil)
    }

    // MARK: Thread-context mutation

    @Test func mutationReachesTopLevelAndAncestorCopies() {
        var root = PostItem(testURI: "at://root")
        var reply = PostItem(testURI: "at://reply", replyParentURI: "at://root")
        reply.threadAncestors = [root]
        var posts = [reply, PostItem(testURI: "at://other")]

        let found = TimelineViewModel.mutatePost(uri: "at://root", in: &posts) {
            $0.isLiked = true
            $0.likeCount += 1
        }
        #expect(found)
        #expect(posts[0].threadAncestors[0].isLiked)
        #expect(posts[0].threadAncestors[0].likeCount == 1)
        #expect(!posts[0].isLiked)
        #expect(!posts[1].isLiked)

        // A post held both as a row and as someone's context updates in both places.
        root.likeCount = 0
        posts.append(root)
        TimelineViewModel.mutatePost(uri: "at://root", in: &posts) { $0.isReposted = true }
        #expect(posts[0].threadAncestors[0].isReposted)
        #expect(posts[2].isReposted)

        #expect(!TimelineViewModel.mutatePost(uri: "at://missing", in: &posts) { _ in })
    }
}
