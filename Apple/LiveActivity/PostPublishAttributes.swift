#if os(iOS)
import ActivityKit
import Foundation

// MARK: - Post Publish Live Activity Attributes
/// The contract between the app (which starts/updates the activity from
/// PostPublisher's progress) and the AtmoWidgets extension (which renders
/// it on the Lock Screen and in the Dynamic Island). Compiled into BOTH
/// targets — ActivityKit matches them by this type.
///
/// `nonisolated`: the Codable conformance must not inherit the targets'
/// default MainActor isolation (ActivityKit encodes off-actor).
nonisolated struct PostPublishAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Preparing media…", "Posting 2 of 3…", "Posted", or the failure
        /// message.
        var stageDescription: String
        /// 0…1 across the whole job.
        var progress: Double
        var isFinished: Bool
        var isFailed: Bool
    }

    /// First-slot preview of the thread being published (fixed for the
    /// activity's lifetime).
    var summary: String
}
#endif
