#if os(iOS)
import UIKit
import ActivityKit
import AtmoCore

// MARK: - Post Publish Bridge (iOS)
/// Wires PostPublisher's background jobs into the platform:
///   • a UIApplication background task keeps a queued publish running
///     when the user leaves the app right after hitting Post;
///   • a Live Activity mirrors the job's progress on the Lock Screen and
///     in the Dynamic Island, ending with the posted/failed result.
/// Installed once from AtmoApp.init().
@MainActor
enum PostPublishBridge {

    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private static var activity: Activity<PostPublishAttributes>? = nil

    static func install() {
        PostPublisher.shared.backgroundActivityHandler = { active in
            if active {
                guard backgroundTask == .invalid else { return }
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "atmo.post.publish") {
                    // Expiration: give the time back; the job itself keeps
                    // its state and the activity reports where it stood.
                    endBackgroundTask()
                }
            } else {
                endBackgroundTask()
            }
        }

        PostPublisher.shared.onUpdate = { update in
            Task { await mirror(update) }
        }
    }

    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// One publisher update → one Live Activity transition.
    private static func mirror(_ update: PostPublisher.Update) async {
        let state = PostPublishAttributes.ContentState(
            stageDescription: update.stageDescription,
            progress: update.progress,
            isFinished: update.isFinished,
            isFailed: update.isFailed
        )
        let content = ActivityContent(state: state, staleDate: nil)

        if update.isFinished || update.isFailed {
            // Success clears itself shortly; a failure stays up so the
            // user sees it (its message points at the saved draft).
            await activity?.end(
                content,
                dismissalPolicy: update.isFailed
                    ? .default
                    : .after(Date.now.addingTimeInterval(4))
            )
            activity = nil
            return
        }

        if let activity {
            await activity.update(content)
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(
                attributes: PostPublishAttributes(summary: update.summary),
                content: content
            )
        }
    }
}
#endif
