import Foundation

// MARK: - Liked Timeline Marker
/// One stop on the Liked list's timeline rail: jumping to `id` (the
/// newest post of the period, which is how the list orders) lands at the
/// top of that day/month/year.
public struct LikedTimelineMarker: Identifiable, Equatable, Sendable {
    /// URI of the newest post in the period — the scroll anchor.
    public let id: String
    /// Short rail label ("12", "Sep", "2025").
    public let label: String
    /// Bubble label shown while scrubbing ("Sep 12, 2025", "September
    /// 2025", "2025").
    public let fullLabel: String
    /// Period boundary one level up (month boundary in day mode, year
    /// boundary in month mode; every year in year mode).
    public let isMajor: Bool
    public let date: Date

    public init(id: String, label: String, fullLabel: String, isMajor: Bool, date: Date) {
        self.id = id
        self.label = label
        self.fullLabel = fullLabel
        self.isMajor = isMajor
        self.date = date
    }
}

// MARK: - Liked Timeline Index
/// Pure builder for the timeline rail beside the Liked list: picks a
/// granularity to match the history's span, emits one marker per period
/// (newest first, matching the list), and thins to a displayable count
/// while always keeping the boundary markers.
public enum LikedTimelineIndex {

    public enum Granularity: Equatable, Sendable {
        case days, months, years
    }

    /// Days up to two months, months up to three years, years beyond.
    public static func granularity(spanning span: TimeInterval) -> Granularity {
        let day: TimeInterval = 86_400
        if span >= 3 * 365 * day { return .years }
        if span >= 60 * day { return .months }
        return .days
    }

    /// Markers for a newest-first liked history. Fewer than two posts (or
    /// an empty span) yields no rail.
    public static func markers(
        for posts: [LikedPost],
        calendar: Calendar = .current,
        maxCount: Int = 40
    ) -> [LikedTimelineMarker] {
        guard posts.count > 1,
              let newest = posts.first?.likedAt,
              let oldest = posts.last?.likedAt
        else { return [] }

        let granularity = granularity(spanning: newest.timeIntervalSince(oldest))

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        let shortMonths = calendar.shortMonthSymbols

        var result: [LikedTimelineMarker] = []
        var lastKey: DateComponents? = nil
        var lastBoundary: Int? = nil    // year (months mode) / month (days mode)

        for post in posts {
            let key: DateComponents
            switch granularity {
            case .years:  key = calendar.dateComponents([.year], from: post.likedAt)
            case .months: key = calendar.dateComponents([.year, .month], from: post.likedAt)
            case .days:   key = calendar.dateComponents([.year, .month, .day], from: post.likedAt)
            }
            guard key != lastKey else { continue }
            lastKey = key

            let label: String
            let fullLabel: String
            let isMajor: Bool
            switch granularity {
            case .years:
                let year = key.year ?? 0
                label = String(year)
                fullLabel = String(year)
                isMajor = true
            case .months:
                let year = key.year ?? 0
                let month = key.month ?? 1
                isMajor = year != lastBoundary
                lastBoundary = year
                label = isMajor ? String(year) : shortMonths[month - 1]
                fullLabel = monthFormatter.string(from: post.likedAt)
            case .days:
                let month = key.month ?? 1
                isMajor = month != lastBoundary
                lastBoundary = month
                label = isMajor ? shortMonths[month - 1] : String(key.day ?? 0)
                fullLabel = dayFormatter.string(from: post.likedAt)
            }

            result.append(LikedTimelineMarker(
                id: post.uri,
                label: label,
                fullLabel: fullLabel,
                isMajor: isMajor,
                date: post.likedAt
            ))
        }

        return thinned(result, to: maxCount)
    }

    /// Caps the marker count for the rail's limited height: boundary
    /// markers always survive; the rest thin evenly.
    static func thinned(_ markers: [LikedTimelineMarker], to maxCount: Int) -> [LikedTimelineMarker] {
        guard markers.count > maxCount else { return markers }

        let majors = markers.filter(\.isMajor)
        guard majors.count < maxCount else {
            // Pathological span (more boundaries than rail slots): keep an
            // even sample of the boundaries themselves.
            let stride = Int((Double(majors.count) / Double(maxCount)).rounded(.up))
            return majors.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
        }

        let minorBudget = maxCount - majors.count
        let minors = markers.filter { !$0.isMajor }
        let stride = Int((Double(minors.count) / Double(minorBudget)).rounded(.up))
        var keptMinorIDs = Set<String>()
        for (offset, marker) in minors.enumerated() where offset % stride == 0 {
            keptMinorIDs.insert(marker.id)
        }
        return markers.filter { $0.isMajor || keptMinorIDs.contains($0.id) }
    }
}
