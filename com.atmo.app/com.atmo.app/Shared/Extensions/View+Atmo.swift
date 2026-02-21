import SwiftUI

// MARK: - Hashtag Navigation Environment Action
// Propagates a "open Search pre-filled with this hashtag" action down the view tree
// without requiring explicit callback threading through every intermediate view.
// AppNavigation sets this on its root view; any descendant (FeedItemView, ThreadView,
// etc.) reads it via @Environment and calls it when a #hashtag is tapped.

struct HashtagSearchAction {
    /// Opens the Search tab/view with `tag` (without the "#") pre-filled and searched.
    var activate: (String) -> Void = { _ in }
    func callAsFunction(_ tag: String) { activate(tag) }
}

private struct HashtagSearchActionKey: EnvironmentKey {
    static let defaultValue = HashtagSearchAction()
}

extension EnvironmentValues {
    var hashtagSearch: HashtagSearchAction {
        get { self[HashtagSearchActionKey.self] }
        set { self[HashtagSearchActionKey.self] = newValue }
    }
}

// MARK: - Spotlight Open-Post Environment Action
// Propagates a "open this post URI in ThreadView" command down the view tree.
// AtmoApp injects this when it receives a CSSearchableItem user activity;
// AppNavigation reads it and navigates to the thread.

struct OpenPostAction {
    var open: (String) -> Void = { _ in }
    func callAsFunction(_ uri: String) { open(uri) }
}

private struct OpenPostActionKey: EnvironmentKey {
    static let defaultValue = OpenPostAction()
}

extension EnvironmentValues {
    var openPost: OpenPostAction {
        get { self[OpenPostActionKey.self] }
        set { self[OpenPostActionKey.self] = newValue }
    }
}

// MARK: - Draft Saved Environment Action
// Propagates a "show draft-saved toast" notification up to AppNavigation without
// requiring explicit callback threading through PostActionsView and other callers.
// AppNavigation injects this at the root; ComposerView reads and calls it when
// a draft is auto-saved via swipe-to-dismiss.

struct DraftSavedAction {
    var notify: () -> Void = {}
    func callAsFunction() { notify() }
}

private struct DraftSavedActionKey: EnvironmentKey {
    static let defaultValue = DraftSavedAction()
}

extension EnvironmentValues {
    var draftSaved: DraftSavedAction {
        get { self[DraftSavedActionKey.self] }
        set { self[DraftSavedActionKey.self] = newValue }
    }
}

extension View {
    /// Conditionally applies a modifier based on a boolean condition.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Applies a platform-specific modifier for iOS or macOS.
    @ViewBuilder
    func iOSOnly<Content: View>(_ transform: (Self) -> Content) -> some View {
#if os(iOS)
        transform(self)
#else
        self
#endif
    }

    @ViewBuilder
    func macOSOnly<Content: View>(_ transform: (Self) -> Content) -> some View {
#if os(macOS)
        transform(self)
#else
        self
#endif
    }
}

// MARK: - App-wide Notification Names
extension Notification.Name {
    /// Posted by ComposerViewModel after a post (or thread) is successfully submitted.
    /// Observers like ProfileViewModel use this to refresh their feeds.
    static let atmoDidSubmitPost = Notification.Name("com.atmo.app.didSubmitPost")

    /// Posted by TimelineViewModel when the app should perform a background refresh.
    /// Fires on the periodic timer and when the app returns to the foreground.
    static let atmoRequestTimelineRefresh = Notification.Name("com.atmo.app.requestTimelineRefresh")
}

// MARK: - String + AT Protocol Helpers
extension String {
    /// Returns true if this looks like a valid Bluesky handle.
    var isValidHandle: Bool {
        let parts = self.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
    }

    /// Returns true if this looks like a DID (decentralized identifier).
    var isDID: Bool {
        hasPrefix("did:")
    }
}
