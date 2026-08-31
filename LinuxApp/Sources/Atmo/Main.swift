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
        .defaultSize(width: 480, height: 780)
        .quitShortcut()
    }
}
