import Adwaita
import Foundation
import AtmoCore

extension MainView {

    /// Value snapshot of one thread page. Counts come from the seeded
    /// interactions model (it owns like/repost optimistic state); shape
    /// (order, depth) comes from the ThreadViewModel.
    struct ThreadPageSnapshot {
        struct Reply: Identifiable, Equatable {
            var id: String { row.id }
            let row: PostRowSnapshot
            let depth: Int
        }

        var root: PostRowSnapshot?
        var replies: [Reply] = []
        var isLoading = false
        var focusedURI: String?
        var loadFailed = false
    }

    func threadSnapshot(uri: String) -> ThreadPageSnapshot {
        _ = tick
        return onMain {
            let session = AppSession.shared.threadSession(for: uri)
            let interactions = Dictionary(
                session.interactions.posts.map { ($0.uri, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // Prefer the interactions copy — it carries optimistic
            // like/repost state the thread model doesn't see.
            func freshest(_ post: PostItem) -> PostItem {
                interactions[post.uri] ?? post
            }
            var snapshot = ThreadPageSnapshot()
            snapshot.root = session.thread.rootPost.map { PostRowSnapshot(post: freshest($0)) }
            snapshot.replies = session.thread.sortedReplies(.time).map {
                ThreadPageSnapshot.Reply(
                    row: PostRowSnapshot(post: freshest($0.post)),
                    depth: $0.depth
                )
            }
            snapshot.isLoading = session.thread.isLoading
            snapshot.focusedURI = session.thread.focusedPostURI
            snapshot.loadFailed = session.thread.error != nil
            return snapshot
        }
    }

    @ViewBuilder func threadPage(uri: String) -> Body {
        let snapshot = threadSnapshot(uri: uri)
        VStack {
            if snapshot.root == nil {
                if snapshot.loadFailed {
                    StatusPage(
                        "Couldn't load the thread",
                        icon: .custom(name: "dialog-error-symbolic"),
                        description: "Check your connection and try again."
                    ) {
                        Button("Try Again") { reloadThread(uri: uri) }
                            .pill()
                            .halign(.center)
                    }
                    .vexpand()
                } else {
                    Spinner()
                        .vexpand()
                        .valign(.center)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if let root = snapshot.root {
                            postRow(root, actions: .thread(uri: uri), showsAncestors: false)
                                .style("card", active: root.id == snapshot.focusedURI)
                            Separator()
                        }
                        ForEach(snapshot.replies, id: \.id) { reply in
                            postRow(reply.row, actions: .thread(uri: uri), showsAncestors: false)
                                // Indentation shows nesting; capped so deep
                                // threads keep readable line lengths.
                                .padding(min(reply.depth, 6) * 16, .leading)
                                .style("card", active: reply.id == snapshot.focusedURI)
                            Separator()
                        }
                    }
                    .frame(maxWidth: 720)
                }
                .vexpand()
                threadReplyBar(uri: uri)
            }
        }
    }

    func reloadThread(uri: String) {
        runCore {
            let session = AppSession.shared.threadSession(for: uri)
            await session.thread.load()
            session.interactions.seedPosts(session.thread.allPosts)
        }
    }

    @ViewBuilder func threadReplyBar(uri: String) -> Body {
        HStack(spacing: 8) {
            Entry("Reply to this thread…", text: $threadReplyText)
                .activate { submitThreadReply(uri: uri) }
                .hexpand()
            Button(icon: .custom(name: "document-edit-symbolic")) {
                if let root = onMain({ AppSession.shared.threadSession(for: uri).thread.rootPost }) {
                    openComposer(replyTo: root)
                }
            }
            .tooltip("Reply with the full composer")
            .flat()
            Button("Reply") { submitThreadReply(uri: uri) }
                .style("suggested-action")
                .insensitive(!canSubmitThreadReply)
        }
        .padding(10)
    }

    var canSubmitThreadReply: Bool {
        let trimmed = threadReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && threadReplyText.count <= 300
    }

    /// Replies to the thread's root through the shared ComposerViewModel
    /// (facets, reply refs, and publishing all come from core), then
    /// reloads the thread so the new reply appears in place.
    func submitThreadReply(uri: String) {
        guard canSubmitThreadReply else { return }
        let text = threadReplyText
        threadReplyText = ""
        runCore {
            let session = AppSession.shared.threadSession(for: uri)
            guard let root = session.thread.rootPost else { return }
            let composer = ComposerViewModel(service: AppSession.shared.service, replyTo: root)
            composer.slots[0].text = text
            await composer.submit()
            if composer.didSubmitSuccessfully {
                await session.thread.load()
                session.interactions.seedPosts(session.thread.allPosts)
            } else {
                threadReplyText = text
                presentError("The reply couldn't be sent. Check your connection and try again.")
            }
        }
    }
}
