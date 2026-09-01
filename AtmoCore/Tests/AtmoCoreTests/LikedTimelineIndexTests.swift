import Foundation
import Testing
@testable import AtmoCore

/// Covers the timeline rail's pure index: granularity choice, one marker
/// per period with boundary majors, and thinning that keeps boundaries.
struct LikedTimelineIndexTests {

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Month-symbol assertions must not depend on the host locale.
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    @MainActor
    private func liked(_ uri: String, _ dateString: String) -> LikedPost {
        let formatter = ISO8601DateFormatter()
        return LikedPost(post: PostItem(testURI: uri), likedAt: formatter.date(from: dateString)!)
    }

    @Test func granularityFollowsSpan() {
        let day: TimeInterval = 86_400
        #expect(LikedTimelineIndex.granularity(spanning: 10 * day) == .days)
        #expect(LikedTimelineIndex.granularity(spanning: 200 * day) == .months)
        #expect(LikedTimelineIndex.granularity(spanning: 4 * 365 * day) == .years)
    }

    @MainActor
    @Test func dayModeEmitsOneMarkerPerDayWithMonthBoundaryMajors() {
        // Newest first, like the store keeps them.
        let posts = [
            liked("at://a", "2026-09-02T10:00:00Z"),
            liked("at://b", "2026-09-02T08:00:00Z"),   // same day — folded
            liked("at://c", "2026-09-01T12:00:00Z"),
            liked("at://d", "2026-08-30T09:00:00Z"),   // month boundary
        ]
        let markers = LikedTimelineIndex.markers(for: posts, calendar: Self.utc)
        #expect(markers.map(\.id) == ["at://a", "at://c", "at://d"])
        // Newest day of a fresh month wears the month name.
        #expect(markers[0].isMajor && markers[0].label == "Sep")
        #expect(!markers[1].isMajor && markers[1].label == "1")
        #expect(markers[2].isMajor && markers[2].label == "Aug")
    }

    @MainActor
    @Test func monthModeMarksYearBoundaries() {
        let posts = [
            liked("at://a", "2026-02-10T00:00:00Z"),
            liked("at://b", "2026-01-05T00:00:00Z"),
            liked("at://c", "2025-12-20T00:00:00Z"),
            liked("at://d", "2025-11-02T00:00:00Z"),
        ]
        let markers = LikedTimelineIndex.markers(for: posts, calendar: Self.utc)
        #expect(markers.count == 4)
        #expect(markers[0].isMajor && markers[0].label == "2026")
        #expect(!markers[1].isMajor && markers[1].label == "Jan")
        #expect(markers[2].isMajor && markers[2].label == "2025")
        #expect(!markers[3].isMajor && markers[3].label == "Nov")
    }

    @MainActor
    @Test func yearModeEmitsMajorsOnly() {
        let posts = [
            liked("at://a", "2026-06-01T00:00:00Z"),
            liked("at://b", "2024-06-01T00:00:00Z"),
            liked("at://c", "2022-06-01T00:00:00Z"),
        ]
        let markers = LikedTimelineIndex.markers(for: posts, calendar: Self.utc)
        #expect(markers.map(\.label) == ["2026", "2024", "2022"])
        #expect(markers.allSatisfy { $0.isMajor })
    }

    @Test func thinningKeepsMajorsAndRespectsCap() {
        let markers = (0..<100).map { index in
            LikedTimelineMarker(
                id: "at://\(index)",
                label: "\(index)",
                fullLabel: "\(index)",
                isMajor: index % 10 == 0,
                date: Date(timeIntervalSince1970: TimeInterval(1_000_000 - index))
            )
        }
        let thinned = LikedTimelineIndex.thinned(markers, to: 30)
        #expect(thinned.count <= 30)
        // Every major survived.
        #expect(thinned.filter(\.isMajor).count == 10)
        // Order preserved (dates strictly descending in the fixture).
        #expect(thinned.map(\.date) == thinned.map(\.date).sorted(by: >))
    }

    @MainActor
    @Test func tooFewPostsYieldNoRail() {
        #expect(LikedTimelineIndex.markers(for: [], calendar: Self.utc).isEmpty)
        #expect(LikedTimelineIndex.markers(
            for: [liked("at://only", "2026-09-01T00:00:00Z")],
            calendar: Self.utc
        ).isEmpty)
    }
}
