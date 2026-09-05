import Adwaita
import AtmoCore

@main
struct AtmoLinux: App {

    let app = AdwaitaApp(id: "com.stoicswe.atmo")

    var scene: Scene {
        Window(id: "main") { window in
            MainView(app: app, window: window)
        }
        .title("@omic")
        // Sidebar + content, like the macOS window; narrow widths collapse
        // the split view (see MainView.signedInShell).
        .defaultSize(width: 1100, height: 760)
        .minSize(width: 360, height: 480)
        .quitShortcut()
    }
}
