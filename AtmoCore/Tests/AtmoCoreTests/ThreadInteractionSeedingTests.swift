import Foundation
import Testing
@testable import AtmoCore

/// seedPosts turns a TimelineViewModel into a thread page's static
/// interaction store — automatic home-feed fetching must stop, or the
/// poll would prepend timeline posts into the seeded thread list.
@MainActor
struct ThreadInteractionSeedingTests {

    @Test func seedingStopsAutomaticFetching() async {
        let vm = TimelineViewModel(service: ATProtoService())
        // Let the init-deferred setup task run so the poll timer exists.
        await Task.yield()
        await Task.yield()

        vm.seedPosts([PostItem(testURI: "at://did:t/app.bsky.feed.post/root")])

        #expect(vm.isSeeded)
        #expect(vm.refreshTimerTask == nil)
        #expect(vm.posts.count == 1)

        // The silent new-post check (fired by foregrounding and post
        // submission) must be inert on a seeded store.
        let result = await vm.checkForNewPosts()
        #expect(result.count == 0)
        #expect(vm.posts.count == 1)
    }
}
