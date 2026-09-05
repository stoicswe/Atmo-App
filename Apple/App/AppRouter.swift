import Foundation
import Observation
import AtmoCore

// MARK: - App Router
/// Requests to navigate that originate outside the view tree — App
/// Intents (Siri, Shortcuts, Spotlight entities) and, in future, deep
/// links. AppNavigation watches these and consumes them once handled.
/// Also hands intents the live service, since they run in the app
/// process but outside SwiftUI's environment.
@Observable
@MainActor
final class AppRouter {
    static let shared = AppRouter()

    /// Switch to a section (Home, Search, Bookmarks, …). Never the Vault.
    var pendingItem: SidebarItem? = nil
    /// Open a post's thread.
    var pendingPostURI: String? = nil
    /// Open a profile.
    var pendingProfileDID: String? = nil
    /// Open a conversation (Reply privately on a ghost post).
    var pendingConversation: ConversationItem? = nil
    /// Open Search and run this query.
    var pendingSearchQuery: String? = nil
    /// Open the composer, seeded with this text (may be empty).
    var pendingComposerText: String? = nil

    /// The app's ATProto service, registered at launch.
    var service: ATProtoService? = nil

    private init() {}
}
