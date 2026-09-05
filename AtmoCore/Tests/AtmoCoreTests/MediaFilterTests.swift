import Foundation
import Testing
@testable import AtmoCore

/// The search results' media filter: All keeps everything; the media
/// filters keep only posts whose own embed is that kind.
struct MediaFilterTests {

    @Test @MainActor func postWithoutEmbedOnlyMatchesAll() {
        let post = PostItem(testURI: "at://p/1")
        #expect(post.media == nil)
        #expect(MediaFilter.all.matches(post))
        #expect(!MediaFilter.images.matches(post))
        #expect(!MediaFilter.videos.matches(post))
        #expect(!MediaFilter.gifs.matches(post))
        #expect(MediaFilter.all.apply([post]).count == 1)
        #expect(MediaFilter.gifs.apply([post]).isEmpty)
    }

    @Test func filterNamesAndOrder() {
        #expect(MediaFilter.allCases.map(\.displayName) == ["All", "Images", "Videos", "GIFs"])
        #expect(MediaFilter.allCases.first == .all)
    }
}
