import Foundation
import Testing
@testable import AtmoCore

/// Covers DM timestamp burst-grouping: same-sender messages within a
/// minute share one timestamp, shown under the last of the burst.
struct MessageTimestampTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private let me = "did:example:me"
    private let them = "did:example:them"

    private func msg(_ id: String, from sender: String, at offset: TimeInterval) -> MessageItem {
        MessageItem(testID: id, senderDID: sender, sentAt: t0.addingTimeInterval(offset))
    }

    @Test func rapidBurstShowsOnlyTheLastTimestamp() {
        let messages = [
            msg("1", from: me, at: 0),
            msg("2", from: me, at: 10),
            msg("3", from: me, at: 30),
        ]
        #expect(!ConversationDetailViewModel.showsTimestamp(at: 0, in: messages))
        #expect(!ConversationDetailViewModel.showsTimestamp(at: 1, in: messages))
        #expect(ConversationDetailViewModel.showsTimestamp(at: 2, in: messages))
    }

    @Test func gapOverAMinuteEndsTheBurst() {
        let messages = [
            msg("1", from: me, at: 0),
            msg("2", from: me, at: 90),
        ]
        #expect(ConversationDetailViewModel.showsTimestamp(at: 0, in: messages))
        #expect(ConversationDetailViewModel.showsTimestamp(at: 1, in: messages))
    }

    @Test func senderChangeEndsTheBurstEvenWhenRapid() {
        let messages = [
            msg("1", from: me, at: 0),
            msg("2", from: them, at: 5),
        ]
        #expect(ConversationDetailViewModel.showsTimestamp(at: 0, in: messages))
        #expect(ConversationDetailViewModel.showsTimestamp(at: 1, in: messages))
    }

    @Test func lastMessageAlwaysShowsATimestamp() {
        let messages = [msg("1", from: me, at: 0)]
        #expect(ConversationDetailViewModel.showsTimestamp(at: 0, in: messages))
    }

    @Test func outOfRangeIndexDefaultsToShowing() {
        #expect(ConversationDetailViewModel.showsTimestamp(at: 5, in: []))
    }
}
