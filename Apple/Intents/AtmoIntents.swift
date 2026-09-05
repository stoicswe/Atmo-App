import AppIntents
import ATProtoKit
import AtmoCore

// MARK: - Errors

enum AtmoIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case emptyText

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "Sign in to Atomic first."
        case .emptyText:   return "The post needs some text."
        }
    }
}

// MARK: - Open Section

struct OpenSectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Section"
    static var description = IntentDescription("Opens a section of Atomic — Home, Search, Activity, Messages, Bookmarks, and more.")
    static var openAppWhenRun = true

    @Parameter(title: "Section")
    var section: AppSection

    init() {}
    init(section: AppSection) { self.section = section }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingItem = section.sidebarItem
        return .result()
    }
}

// MARK: - Open Bookmark

struct OpenBookmarkIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Bookmarked Post"
    static var description = IntentDescription("Opens one of your bookmarked posts.")
    static var openAppWhenRun = true

    @Parameter(title: "Bookmark")
    var bookmark: BookmarkEntity

    init() {}
    init(bookmark: BookmarkEntity) { self.bookmark = bookmark }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingPostURI = bookmark.id
        return .result()
    }
}

// MARK: - Search Bookmarks

struct SearchBookmarksIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Bookmarks"
    static var description = IntentDescription("Finds bookmarked posts by author or text. Posts in the Vault are never included.")

    @Parameter(title: "Search")
    var query: String

    init() {}
    init(query: String) { self.query = query }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[BookmarkEntity]> & ProvidesDialog {
        let results = try await BookmarkQuery().entities(matching: query)
        let dialog: IntentDialog
        switch results.count {
        case 0:
            dialog = "No bookmarks match \"\(query)\"."
        case 1:
            dialog = "Found one bookmark, from \(results[0].authorName)."
        default:
            let names = results.prefix(3).map(\.authorName).joined(separator: ", ")
            dialog = "Found \(results.count) bookmarks, from \(names)\(results.count > 3 ? ", and more" : "")."
        }
        return .result(value: Array(results), dialog: dialog)
    }
}

// MARK: - Bookmark Count

struct BookmarkCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Count Bookmarks"
    static var description = IntentDescription("Tells you how many posts you've bookmarked (not counting the Vault).")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = BookmarkStore.shared.bookmarks.count
        let dialog: IntentDialog = count == 1
            ? "You have one bookmarked post."
            : "You have \(count) bookmarked posts."
        return .result(value: count, dialog: dialog)
    }
}

// MARK: - Search Bluesky

struct SearchBlueskyIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Bluesky"
    static var description = IntentDescription("Opens Atomic and searches Bluesky for posts, people, hashtags, and feeds.")
    static var openAppWhenRun = true

    @Parameter(title: "Search")
    var query: String

    init() {}
    init(query: String) { self.query = query }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingSearchQuery = query
        return .result()
    }
}

// MARK: - Compose

struct ComposePostIntent: AppIntent {
    static var title: LocalizedStringResource = "New Post"
    static var description = IntentDescription("Opens the composer, optionally with text already typed.")
    static var openAppWhenRun = true

    @Parameter(title: "Text", default: "")
    var text: String

    init() {}
    init(text: String) { self.text = text }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingComposerText = text
        return .result()
    }
}

// MARK: - Publish

/// Posts text straight to Bluesky without opening the app — for
/// Shortcuts automations. Uses the same publisher as the composer.
struct PublishPostIntent: AppIntent {
    static var title: LocalizedStringResource = "Post to Bluesky"
    static var description = IntentDescription("Publishes a text post to Bluesky right away.")

    @Parameter(title: "Text")
    var text: String

    init() {}
    init(text: String) { self.text = text }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AtmoIntentError.emptyText }
        guard let service = AppRouter.shared.service, service.isAuthenticated else {
            throw AtmoIntentError.notSignedIn
        }
        let payload = PostThreadPayload(
            slots: [.init(text: trimmed, images: [], video: nil, gif: nil)],
            replyTo: nil,
            quotedPost: nil,
            interactionSettings: PostInteractionSettings(),
            includeTranslationDisclosure: false
        )
        try await PostPublisher.shared.publishNow(payload, service: service)
        return .result(dialog: "Posted to Bluesky.")
    }
}

// MARK: - Unread Activity

struct UnreadActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Unread Activity"
    static var description = IntentDescription("Tells you how many unread notifications you have on Bluesky.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let kit = AppRouter.shared.service?.atProtoKit else {
            throw AtmoIntentError.notSignedIn
        }
        let count = try await kit.getUnreadCount(priority: nil).count
        let dialog: IntentDialog
        switch count {
        case 0:  dialog = "You're all caught up."
        case 1:  dialog = "You have one unread notification."
        default: dialog = "You have \(count) unread notifications."
        }
        return .result(value: count, dialog: dialog)
    }
}

// MARK: - Shortcuts

/// Registers the intents with Siri and Shortcuts, phrases included, so
/// they work by voice with no setup.
struct AtmoShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSectionIntent(),
            phrases: [
                "Open \(\.$section) in \(.applicationName)",
                "Show \(\.$section) in \(.applicationName)",
                "Go to \(\.$section) in \(.applicationName)",
            ],
            shortTitle: "Open Section",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: OpenBookmarkIntent(),
            phrases: [
                "Open \(\.$bookmark) in \(.applicationName)",
                "Show my bookmark \(\.$bookmark) in \(.applicationName)",
            ],
            shortTitle: "Open Bookmark",
            systemImageName: "bookmark.fill"
        )
        AppShortcut(
            intent: SearchBookmarksIntent(),
            phrases: [
                "Search my bookmarks in \(.applicationName)",
                "Find a bookmark in \(.applicationName)",
                "Look up a bookmarked post in \(.applicationName)",
            ],
            shortTitle: "Search Bookmarks",
            systemImageName: "bookmark.circle"
        )
        AppShortcut(
            intent: SearchBlueskyIntent(),
            phrases: [
                "Search Bluesky in \(.applicationName)",
                "Search in \(.applicationName)",
            ],
            shortTitle: "Search Bluesky",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: FindPostsIntent(),
            // Free-text parameters can't sit in a phrase; Siri asks for
            // the search once the shortcut is invoked.
            phrases: [
                "Find posts on Bluesky in \(.applicationName)",
                "Search Bluesky posts in \(.applicationName)",
                "What is Bluesky saying in \(.applicationName)",
            ],
            shortTitle: "Find Posts",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: FindPeopleIntent(),
            phrases: [
                "Find people on Bluesky in \(.applicationName)",
                "Look up an account in \(.applicationName)",
            ],
            shortTitle: "Find People",
            systemImageName: "person.crop.circle.badge.questionmark"
        )
        AppShortcut(
            intent: OpenProfileIntent(),
            phrases: [
                "Open \(\.$account) in \(.applicationName)",
                "Show \(\.$account)'s profile in \(.applicationName)",
            ],
            shortTitle: "Open Profile",
            systemImageName: "person.crop.circle"
        )
        AppShortcut(
            intent: ComposePostIntent(),
            phrases: [
                "New post in \(.applicationName)",
                "Compose a post in \(.applicationName)",
                "Write a post in \(.applicationName)",
            ],
            shortTitle: "New Post",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: PublishPostIntent(),
            phrases: [
                "Post to Bluesky with \(.applicationName)",
            ],
            shortTitle: "Post to Bluesky",
            systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: UnreadActivityIntent(),
            phrases: [
                "Check my activity in \(.applicationName)",
                "How many notifications do I have in \(.applicationName)",
                "Any new activity in \(.applicationName)",
            ],
            shortTitle: "Unread Activity",
            systemImageName: "bell.fill"
        )
    }
}
