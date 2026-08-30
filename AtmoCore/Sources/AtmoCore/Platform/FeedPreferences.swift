import Foundation

/// Cross-platform feed behavior preferences, shared by every front end
/// (SwiftUI apps bind reactively via @AppStorage on `infiniteScrollKey`;
/// the GTK app reads the accessors).
public enum FeedPreferences {

    /// UserDefaults key for the infinite-scroll toggle. `true` (default):
    /// the feed pages in more posts automatically as the user nears the
    /// end. `false`: a manual "Load More" control appears instead.
    public static let infiniteScrollKey = "atmo.pref.infiniteScroll"

    public static var infiniteScrollEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: infiniteScrollKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: infiniteScrollKey)
        }
    }
}
