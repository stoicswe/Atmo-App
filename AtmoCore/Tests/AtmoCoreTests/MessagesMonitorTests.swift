import Foundation
import Testing
@testable import AtmoCore

/// Covers the DM poller's arrival detection — what deserves a notification.
struct MessagesMonitorTests {

    private let me = "did:plc:me"
    private let friend = "did:plc:friend"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func convo(
        _ id: String,
        lastAt: Date?,
        sender: String?,
        unread: Int
    ) -> ConversationItem {
        ConversationItem(
            testID: id,
            lastMessage: "hey",
            lastMessageAt: lastAt,
            lastMessageSenderDID: sender,
            unreadCount: unread
        )
    }

    @Test func firstFetchOfTheSessionNeverNotifies() {
        let fresh = [convo("c1", lastAt: t0, sender: friend, unread: 3)]
        #expect(MessagesMonitor.incomingConversations(fresh: fresh, lastSeen: nil, currentUserDID: me).isEmpty)
    }

    @Test func newerUnreadIncomingMessageNotifies() {
        let fresh = [convo("c1", lastAt: t0.addingTimeInterval(60), sender: friend, unread: 1)]
        let result = MessagesMonitor.incomingConversations(
            fresh: fresh, lastSeen: ["c1": t0], currentUserDID: me
        )
        #expect(result.map(\.convoID) == ["c1"])
    }

    @Test func ownOutgoingMessageDoesNotNotify() {
        let fresh = [convo("c1", lastAt: t0.addingTimeInterval(60), sender: me, unread: 1)]
        #expect(MessagesMonitor.incomingConversations(fresh: fresh, lastSeen: ["c1": t0], currentUserDID: me).isEmpty)
    }

    @Test func unchangedConversationDoesNotNotify() {
        let fresh = [convo("c1", lastAt: t0, sender: friend, unread: 2)]
        #expect(MessagesMonitor.incomingConversations(fresh: fresh, lastSeen: ["c1": t0], currentUserDID: me).isEmpty)
    }

    @Test func readConversationDoesNotNotify() {
        let fresh = [convo("c1", lastAt: t0.addingTimeInterval(60), sender: friend, unread: 0)]
        #expect(MessagesMonitor.incomingConversations(fresh: fresh, lastSeen: ["c1": t0], currentUserDID: me).isEmpty)
    }

    @Test func brandNewConversationWithUnreadNotifies() {
        let fresh = [convo("c-new", lastAt: t0, sender: friend, unread: 1)]
        let result = MessagesMonitor.incomingConversations(
            fresh: fresh, lastSeen: ["other": t0], currentUserDID: me
        )
        #expect(result.map(\.convoID) == ["c-new"])
    }

    @Test func alertIsThreadedPerConversationAndKeyedByArrival() {
        let convo = convo("c1", lastAt: t0, sender: friend, unread: 1)
        let alert = MessagesMonitor.alert(for: convo)
        #expect(alert.id == "dm.c1.\(t0.timeIntervalSince1970)")
        if case .directMessage(let conversationID) = alert.kind {
            #expect(conversationID == "c1")
        } else {
            Issue.record("expected a directMessage alert kind")
        }
        #expect(alert.body == "hey")
    }
}
