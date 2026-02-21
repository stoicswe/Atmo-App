import Foundation

extension Date {
    /// Returns a compact relative time string for feed display.
    /// - Under 1 minute: "now"
    /// - Under 1 hour: "Xm"
    /// - Under 24 hours: "Xh"
    /// - Under 7 days: "Xd"
    /// - Otherwise: abbreviated date (e.g., "Jan 5")
    func atmoFormatted() -> String {
        let now = Date.now
        let interval = now.timeIntervalSince(self)

        switch interval {
        case ..<60:
            return "now"
        case 60..<3600:
            let minutes = Int(interval / 60)
            return "\(minutes)m"
        case 3600..<86400:
            let hours = Int(interval / 3600)
            return "\(hours)h"
        case 86400..<(86400 * 7):
            let days = Int(interval / 86400)
            return "\(days)d"
        default:
            return Self.abbreviatedFormatter.string(from: self)
        }
    }

    private static let abbreviatedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
