import Foundation
import Testing
@testable import AtmoCore

/// Covers explicit-media label detection and the Show/Blur/Hide policy.
struct SensitiveMediaTests {

    @Test func adultLabelsAreDetected() {
        for label in ["porn", "sexual", "nudity", "graphic-media", "gore"] {
            let post = PostItem(testURI: "at://a/p/1", contentLabels: [label])
            #expect(post.hasSensitiveMediaLabel, "\(label) should flag the post")
        }
    }

    @Test func unrelatedLabelsDoNotFlag() {
        let post = PostItem(testURI: "at://a/p/1", contentLabels: ["spam", "!warn"])
        #expect(!post.hasSensitiveMediaLabel)
    }

    @Test func unlabeledPostIsClean() {
        #expect(!PostItem(testURI: "at://a/p/1").hasSensitiveMediaLabel)
    }

    @Test func policyDefaultsToBlur() {
        #expect(SensitiveMediaPolicy.stored(rawValue: nil) == .blur)
        #expect(SensitiveMediaPolicy.stored(rawValue: "garbage") == .blur)
        #expect(SensitiveMediaPolicy.stored(rawValue: "show") == .show)
        #expect(SensitiveMediaPolicy.stored(rawValue: "hide") == .hide)
    }
}
