import Foundation
import Testing
@testable import AtmoCore

/// Covers the client-side video-upload limits (Bluesky: MP4, ≤ 100 MB,
/// ≤ 3 minutes).
struct VideoConstraintsTests {

    @Test func withinLimitsPasses() {
        #expect(VideoConstraints.validate(byteCount: 50_000_000, duration: 60) == nil)
    }

    @Test func exactMaximumDurationPasses() {
        #expect(VideoConstraints.validate(byteCount: 1_000, duration: VideoConstraints.maxDuration) == nil)
    }

    @Test func overlongClipIsRejectedBeforeSize() {
        // Length can't be fixed by compression, so it must win even when
        // the byte count is also over.
        let violation = VideoConstraints.validate(byteCount: VideoConstraints.maxByteCount, duration: 200)
        #expect(violation == .tooLong(seconds: 200))
    }

    @Test func oversizedFileIsRejected() {
        let violation = VideoConstraints.validate(byteCount: VideoConstraints.maxByteCount, duration: 30)
        #expect(violation == .tooLarge(byteCount: VideoConstraints.maxByteCount))
    }

    @Test func unknownDurationOnlyChecksSize() {
        #expect(VideoConstraints.validate(byteCount: 10, duration: nil) == nil)
    }

    @Test func violationsCarryUserMessages() {
        #expect(!VideoConstraints.Violation.tooLong(seconds: 200).userMessage.isEmpty)
        #expect(!VideoConstraints.Violation.tooLarge(byteCount: 1).userMessage.isEmpty)
    }
}
