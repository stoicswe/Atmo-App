import Foundation
import AtmoCore

/// GTK dispatches every callback on the main thread; AtmoCore's service
/// and view-model classes are `@MainActor`. This bridges the toolkit's
/// nonisolated view context onto that guarantee for *synchronous* reads.
/// Async work goes through `Task { @MainActor in … }` instead, which the
/// MainLoopBridge keeps running.
func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    try MainActor.assumeIsolated(body)
}

/// Owns the AtmoCore service stack for the window. Adwaita's `@State`
/// holds value snapshots only, so the reference-typed models live here
/// and the views read them through `onMain`.
@MainActor
final class AppSession {
    static let shared = AppSession()

    let service: ATProtoService
    private(set) var timeline: TimelineViewModel?
    private(set) var notifications: NotificationsViewModel?
    private(set) var search: SearchViewModel?
    private(set) var dms: DMsViewModel?
    private(set) var newConversation: NewConversationViewModel?

    /// The composer behind the open compose dialog (nil while closed).
    var composer: ComposerViewModel?
    /// The "send post in a message" picker behind its dialog.
    var sendPost: SendPostViewModel?

    /// One thread page's models: the thread itself plus a seeded
    /// TimelineViewModel that owns like/repost with optimistic updates —
    /// the same split as the Apple ThreadView.
    struct ThreadSession {
        let thread: ThreadViewModel
        let interactions: TimelineViewModel
    }

    /// One profile page's models: the profile (header, follow, feed
    /// filter, posts) plus a seeded interaction store for its rows.
    struct ProfileSession {
        let profile: ProfileViewModel
        let interactions: TimelineViewModel
        /// URIs the interaction store was last seeded with — re-seed only
        /// when the profile feed actually changed, so optimistic state
        /// survives re-renders.
        var seededURIs: [String] = []
    }

    /// Loaded threads, keyed by the opened post's URI. Kept for the whole
    /// signed-in session so re-opening a thread is instant; reset clears it.
    private var threads: [String: ThreadSession] = [:]
    private var profiles: [String: ProfileSession] = [:]
    private var conversations: [String: ConversationDetailViewModel] = [:]

    /// Like/repost store for search result rows (SearchViewModel has no
    /// interaction path of its own). Seeded from the current results.
    private var searchInteractions: TimelineViewModel?
    private var searchSeededURIs: [String] = []

    /// Key for the signed-in user's own profile session.
    nonisolated static let ownProfileKey = "me"

    private init() {
        // Swap in a libsecret-backed SecretsStoring implementation when
        // one lands; the file store keeps 0600-permission JSON under
        // ~/.local/share (see FileCredentialStore) and UserDefaults on
        // Linux writes ~/.config-style plists via corelibs-foundation.
        Atmo.platform = AtmoPlatform(
            makeCredentialStore: { FileCredentialStore() },
            timelineRefreshInterval: 60,
            mediaProcessor: PixbufMediaProcessor()
        )
        service = ATProtoService()
    }

    /// Build the per-session view models after authentication succeeds.
    func buildViewModels() {
        guard timeline == nil else { return }
        timeline = TimelineViewModel(service: service)
        notifications = NotificationsViewModel(service: service)
        search = SearchViewModel(service: service)
        dms = DMsViewModel(service: service)
        newConversation = NewConversationViewModel(service: service)
        GhostPostStore.shared.attach(service: service)
    }

    /// The models behind one thread page, created on first open.
    func threadSession(for postURI: String) -> ThreadSession {
        if let existing = threads[postURI] { return existing }
        let session = ThreadSession(
            thread: ThreadViewModel(service: service, postURI: postURI),
            interactions: TimelineViewModel(service: service)
        )
        threads[postURI] = session
        return session
    }

    /// Normalizes a profile key: the signed-in user's DID or handle maps
    /// to the shared own-profile session.
    func profileKey(for actor: String?) -> String {
        guard let actor, !actor.isEmpty else { return Self.ownProfileKey }
        if actor == service.currentUserDID || actor == service.currentHandle { return Self.ownProfileKey }
        return actor
    }

    /// The models behind one profile page, created on first open.
    func profileSession(for key: String) -> ProfileSession {
        if let existing = profiles[key] { return existing }
        let actorDID: String? = key == Self.ownProfileKey ? nil : key
        let session = ProfileSession(
            profile: ProfileViewModel(service: service, actorDID: actorDID),
            interactions: TimelineViewModel(service: service)
        )
        profiles[key] = session
        return session
    }

    /// Keeps a profile's interaction store in step with its post list.
    func syncProfileInteractions(for key: String) {
        guard var session = profiles[key] else { return }
        let uris = session.profile.posts.map(\.uri)
        guard uris != session.seededURIs else { return }
        session.interactions.seedPosts(session.profile.posts)
        session.seededURIs = uris
        profiles[key] = session
    }

    /// Like/repost store for search rows, seeded from the live results.
    func searchInteractionStore() -> TimelineViewModel? {
        guard let search else { return nil }
        let store = searchInteractions ?? TimelineViewModel(service: service)
        searchInteractions = store
        let uris = search.postResults.map(\.uri)
        if uris != searchSeededURIs {
            store.seedPosts(search.postResults)
            searchSeededURIs = uris
        }
        return store
    }

    /// The model behind one conversation page, created on first open.
    func conversation(for convoID: String) -> ConversationDetailViewModel {
        if let existing = conversations[convoID] { return existing }
        let model = ConversationDetailViewModel(conversationID: convoID, service: service)
        conversations[convoID] = model
        return model
    }

    /// Tear down after logout.
    func reset() {
        timeline = nil
        notifications = nil
        search = nil
        dms = nil
        newConversation = nil
        composer = nil
        sendPost = nil
        threads = [:]
        profiles = [:]
        conversations = [:]
        searchInteractions = nil
        searchSeededURIs = []
    }
}
