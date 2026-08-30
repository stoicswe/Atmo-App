import Foundation

// In-process events AtmoCore posts through NotificationCenter so that
// independent view models can react without holding references to each
// other. NotificationCenter is part of Foundation and works on Linux.
extension Notification.Name {
    /// Posted after the composer successfully submits a post or thread.
    /// Observed by `ProfileViewModel` to refresh the author feed.
    public static let atmoDidSubmitPost = Notification.Name("com.atmo.app.didSubmitPost")
}

extension NotificationCenter {
    /// Cross-platform, Sendable-safe replacement for `notifications(named:)`
    /// for observers that don't need the notification payload. Bridges the
    /// classic observer API into an `AsyncStream` that ends when the
    /// consuming task is cancelled. (`Notification` itself is not Sendable,
    /// and `notifications(named:)` is unavailable in swift-corelibs-foundation.)
    func signals(named name: Notification.Name) -> AsyncStream<Void> {
        AsyncStream { continuation in
            // The observer token is not Sendable; box it so the @Sendable
            // onTermination closure can carry it back to removeObserver.
            let token = ObserverBox(
                self.addObserver(forName: name, object: nil, queue: nil) { _ in
                    continuation.yield(())
                }
            )
            continuation.onTermination = { [weak self] _ in
                self?.removeObserver(token.value)
            }
        }
    }
}

/// NotificationCenter observer tokens are thread-safe to hand back to
/// `removeObserver` from any thread, but their type predates Sendable.
private final class ObserverBox: @unchecked Sendable {
    let value: NSObjectProtocol
    init(_ value: NSObjectProtocol) { self.value = value }
}
