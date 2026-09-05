import Adwaita
import Foundation
import AtmoCore

extension MainView {

    struct RetentionOption: Identifiable, CustomStringConvertible {
        let id: String
        let description: String
    }

    var retentionOptions: [RetentionOption] {
        LikedPostsRetention.allCases.map { RetentionOption(id: $0.rawValue, description: $0.displayName) }
    }

    /// The Apple Settings tabs that apply here (Appearance, Features,
    /// Account, About), as one Adwaita preferences page. Apple-only
    /// sections (Family, notifications scheduling, Wallet pass) are
    /// listed in PORTING.md.
    @ViewBuilder var settingsPane: Body {
        ScrollView {
            VStack(spacing: 18) {
                settingsGroup("Appearance") {
                    ComboRow("Theme", selection: colorSchemeBinding, values: Desktop.ColorScheme.allCases)
                        .subtitle("Follow GNOME's style, or pin the app to light or dark.")
                }
                settingsGroup("Feed") {
                    SwitchRow("Infinite scroll", isOn: defaultsBool(FeedPreferences.infiniteScrollKey, default: true))
                        .subtitle("On: the timeline keeps loading older posts as you near the end. Off: a Load More button appears instead.")
                }
                settingsGroup("Features") {
                    SwitchRow("Search history", isOn: searchHistoryBinding)
                        .subtitle("Your last few searches appear above the search bar as quick suggestions. Kept only on this device.")
                    SwitchRow("Ghost posts", isOn: defaultsBool(GhostPostPolicy.enabledKey, default: false))
                        .subtitle("Adds a Ghost switch to the composer: the post takes itself down after 24 hours, and a Ghosts section joins the sidebar.")
                    ComboRow("Keep liked posts", selection: retentionBinding, values: retentionOptions)
                        .subtitle("How long the Liked section remembers posts you've liked.")
                }
                settingsGroup("Account") {
                    ActionRow("Signed in as")
                        .subtitle("@\(currentHandle)")
                    ActionRow("Server")
                        .subtitle(pdsHost)
                    ActionRow("Credential storage")
                        .subtitle("Refresh token in a 0600 file under ~/.local/share (keyring integration is tracked in PORTING.md).")
                    ButtonRow()
                        .title("Sign Out")
                        .activated { signOut() }
                        .style("destructive-action")
                }
                settingsGroup("About") {
                    ActionRow("@omic for GNOME")
                        .subtitle("Version \(appVersion) · GTK 4 / libadwaita on the shared AtmoCore package.")
                    ButtonRow()
                        .title("About @omic")
                        .activated { aboutVisible = true }
                }
            }
            .padding(18)
            .frame(maxWidth: 640)
        }
        .vexpand()
    }

    @ViewBuilder func settingsGroup(_ title: String, @ViewBuilder rows: @escaping () -> Body) -> Body {
        VStack(spacing: 6) {
            Text(title)
                .style("heading")
                .halign(.start)
            Form(content: rows)
        }
    }

    var pdsHost: String {
        _ = tick
        return onMain { AppSession.shared.service.pdsURL.host ?? "bsky.social" }
    }

    func defaultsBool(_ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(
            get: {
                _ = tick
                return UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
            },
            set: { value in
                UserDefaults.standard.set(value, forKey: key)
                tick += 1
            }
        )
    }

    var searchHistoryBinding: Binding<Bool> {
        Binding(
            get: { onMain { SearchHistoryStore.shared.isEnabled } },
            set: { value in
                onMain { SearchHistoryStore.shared.setEnabled(value) }
                tick += 1
            }
        )
    }

    var retentionBinding: Binding<String> {
        Binding(
            get: { LikedPostsRetention.current.rawValue },
            set: { raw in
                UserDefaults.standard.set(raw, forKey: LikedPostsRetention.storageKey)
                onMain { LikedPostsStore.shared.applyRetention() }
                tick += 1
            }
        )
    }

    var colorSchemeBinding: Binding<String> {
        Binding(
            get: { settingsColorScheme },
            set: { raw in
                settingsColorScheme = raw
                Desktop.ColorScheme(rawValue: raw)?.apply()
            }
        )
    }
}
