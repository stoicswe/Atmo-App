import Adwaita
import Foundation
import AtmoCore

extension MainView {

    /// Minimal composer: a single post with the shared 300-character limit.
    /// Threads, image attachments, replies, and quotes are tracked in
    /// PORTING.md — they reuse ComposerViewModel when they land.
    @ViewBuilder var composeContent: Body {
        VStack(spacing: 8) {
            TextEditor(text: $composeText)
                .innerPadding(8)
                .vexpand()
            HStack(spacing: 8) {
                Text("\(300 - composeText.count)")
                    .style(composeText.count > 300 ? "error" : "dim-label")
                    .hexpand()
                    .halign(.end)
                Button("Post") { submitPost() }
                    .style("suggested-action")
                    .insensitive(!canSubmitPost)
            }
            .padding(8)
        }
    }

    var canSubmitPost: Bool {
        let trimmed = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && composeText.count <= 300
    }

    func submitPost() {
        let text = composeText
        composeVisible = false
        runCore {
            guard let bluesky = AppSession.shared.service.atProtoBluesky else { return }
            do {
                _ = try await bluesky.createPostRecord(text: text, locales: [Locale.current])
                await AppSession.shared.timeline?.checkForNewPosts()
            } catch {
                self.presentError("The post couldn't be sent. Check your connection and try again.")
            }
        }
    }
}
