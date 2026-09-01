import Adwaita
import Foundation
import AtmoCore

extension MainView {

    /// Composer dialog: a single post (or reply) through the shared
    /// ComposerViewModel — facets, reply refs, and publishing come from
    /// core (PostPublisher). Threads, image attachments, and quotes are
    /// tracked in PORTING.md.
    @ViewBuilder var composeContent: Body {
        VStack(spacing: 8) {
            if let replyTo = composeReplyTo {
                Text("↩ Replying to \(replyTo.authorDisplayName ?? "@" + replyTo.authorHandle)")
                    .style("dim-label")
                    .halign(.start)
                    .padding(8, .horizontal)
            }
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
        let replyTo = composeReplyTo
        composeVisible = false
        runCore {
            let composer = ComposerViewModel(service: AppSession.shared.service, replyTo: replyTo)
            composer.slots[0].text = text
            await composer.submit()
            if composer.didSubmitSuccessfully {
                _ = await AppSession.shared.timeline?.checkForNewPosts()
            } else {
                self.presentError("The post couldn't be sent. Check your connection and try again.")
            }
        }
    }
}
