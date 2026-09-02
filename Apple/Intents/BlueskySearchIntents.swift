import AppIntents
import ATProtoKit
import AtmoCore

// MARK: - Post Entity
/// A Bluesky post found through the app's search, for Siri and
/// Shortcuts. Not indexed — these are live results, fetched on demand.
struct PostEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Bluesky Post"
    static var defaultQuery = PostQuery()

    /// The post's AT URI.
    let id: String
    let authorName: String
    let authorHandle: String
    let text: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(authorName)",
            subtitle: "\(text.isEmpty ? "@" + authorHandle : text)"
        )
    }

    init(post: PostItem) {
        self.id = post.uri
        self.authorName = post.authorDisplayName ?? "@\(post.authorHandle)"
        self.authorHandle = post.authorHandle
        self.text = post.text
    }
}

struct PostQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PostEntity] {
        guard let kit = AppRouter.shared.service?.atProtoKit, !identifiers.isEmpty else { return [] }
        let output = try await kit.getPosts(identifiers)
        return output.posts.map { PostEntity(post: PostItem(postView: $0)) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PostEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, let kit = AppRouter.shared.service?.atProtoKit else { return [] }
        let output = try await kit.searchPosts(matching: query, sortRanking: .top, limit: 10)
        return output.posts.map { PostEntity(post: PostItem(postView: $0)) }
    }
}

// MARK: - Person Entity

struct PersonEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Bluesky Account"
    static var defaultQuery = PersonQuery()

    /// The account's DID.
    let id: String
    let handle: String
    let displayName: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName ?? handle)",
            subtitle: "@\(handle)"
        )
    }

    init(profile: ProfileModel) {
        self.id = profile.did
        self.handle = profile.handle
        self.displayName = profile.displayName
    }
}

struct PersonQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PersonEntity] {
        guard let kit = AppRouter.shared.service?.atProtoKit else { return [] }
        var results: [PersonEntity] = []
        for did in identifiers {
            if let output = try? await kit.searchActors(matching: did, limit: 1),
               let first = output.actors.first, first.actorDID == did {
                results.append(PersonEntity(profile: ProfileModel(searchResult: first)))
            }
        }
        return results
    }

    @MainActor
    func entities(matching string: String) async throws -> [PersonEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let kit = AppRouter.shared.service?.atProtoKit else { return [] }
        let output = try await kit.searchActors(matching: query, limit: 10)
        return output.actors.map { PersonEntity(profile: ProfileModel(searchResult: $0)) }
    }
}

// MARK: - Find Posts (live, from Bluesky)

struct FindPostsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Posts on Bluesky"
    static var description = IntentDescription("Searches Bluesky for posts and returns the top matches, using Atomic's search.")

    @Parameter(title: "Search")
    var query: String

    init() {}
    init(query: String) { self.query = query }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[PostEntity]> & ProvidesDialog {
        guard AppRouter.shared.service?.atProtoKit != nil else { throw AtmoIntentError.notSignedIn }
        let results = try await PostQuery().entities(matching: query)
        let dialog: IntentDialog
        switch results.count {
        case 0:
            dialog = "No posts on Bluesky match \"\(query)\"."
        case 1:
            dialog = "Found a post from \(results[0].authorName): \(results[0].text.prefix(120))"
        default:
            let top = results[0]
            dialog = "Found \(results.count) posts. The top one, from \(top.authorName): \(top.text.prefix(120))"
        }
        return .result(value: results, dialog: dialog)
    }
}

// MARK: - Find People (live, from Bluesky)

struct FindPeopleIntent: AppIntent {
    static var title: LocalizedStringResource = "Find People on Bluesky"
    static var description = IntentDescription("Searches Bluesky for accounts by name or handle.")

    @Parameter(title: "Search")
    var query: String

    init() {}
    init(query: String) { self.query = query }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[PersonEntity]> & ProvidesDialog {
        guard AppRouter.shared.service?.atProtoKit != nil else { throw AtmoIntentError.notSignedIn }
        let results = try await PersonQuery().entities(matching: query)
        let dialog: IntentDialog
        switch results.count {
        case 0:
            dialog = "No accounts match \"\(query)\"."
        case 1:
            dialog = "Found \(results[0].displayName ?? results[0].handle), @\(results[0].handle)."
        default:
            let names = results.prefix(3).map { "@" + $0.handle }.joined(separator: ", ")
            dialog = "Found \(results.count) accounts: \(names)\(results.count > 3 ? ", and more" : "")."
        }
        return .result(value: results, dialog: dialog)
    }
}

// MARK: - Open Post / Profile

struct OpenPostIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Post"
    static var description = IntentDescription("Opens a Bluesky post in Atomic.")
    static var openAppWhenRun = true

    @Parameter(title: "Post")
    var post: PostEntity

    init() {}
    init(post: PostEntity) { self.post = post }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingPostURI = post.id
        return .result()
    }
}

struct OpenProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Profile"
    static var description = IntentDescription("Opens a Bluesky account's profile in Atomic.")
    static var openAppWhenRun = true

    @Parameter(title: "Account")
    var account: PersonEntity

    init() {}
    init(account: PersonEntity) { self.account = account }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingProfileDID = account.id
        return .result()
    }
}
