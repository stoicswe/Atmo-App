import SwiftUI
import AtmoCore

// Standalone-watch settings: notification controls and sign-out. These
// mirror the phone's Settings → Notifications tab, but operate on THIS
// device's NotificationSettingsStore — settings are per-device
// (UserDefaults has no shared container across watch and phone), so a
// watch used without its phone configures itself here.
struct WatchSettingsView: View {
    @Environment(ATProtoService.self) private var service
    private var store: NotificationSettingsStore { .shared }

    /// Bumped after store mutations so the toggles re-read their state.
    @State private var revision = 0
    @State private var showSignOutConfirmation = false

    /// Display metadata for one interaction kind (compact watch labels).
    private func label(for reason: NotificationItem.NotificationReason) -> (name: String, icon: String) {
        switch reason {
        case .like:              return ("Likes", "heart")
        case .reply:             return ("Replies", "bubble.left")
        case .mention:           return ("Mentions", "at")
        case .repost:            return ("Reposts", "arrow.2.squarepath")
        case .quote:             return ("Quotes", "quote.bubble")
        case .follow:            return ("Followers", "person.badge.plus")
        // Not in notifiableReasons — labeled for exhaustiveness only.
        case .subscribedPost:    return ("Posts", "bell.badge")
        case .likeViaRepost:     return ("Likes", "heart")
        case .repostViaRepost:   return ("Reposts", "arrow.2.squarepath")
        case .starterpackJoined: return ("Starter Pack", "person.2")
        case .verified,
             .unverified:        return ("Verification", "checkmark.seal")
        case .unknown:           return ("Other", "bell")
        }
    }

    var body: some View {
        let _ = revision
        List {
            Section {
                Toggle("Notifications", isOn: Binding(
                    get: { store.interactionsEnabled },
                    set: { enabled in
                        store.setInteractionsEnabled(enabled)
                        revision += 1
                        if enabled {
                            // First enable: ask watchOS for permission. If
                            // denied, flip back so the UI never promises
                            // notifications that can't arrive.
                            Task { @MainActor in
                                let granted = await Atmo.platform.alertPresenter.requestAuthorization()
                                if !granted {
                                    store.setInteractionsEnabled(false)
                                    revision += 1
                                }
                            }
                        }
                    }
                ))
            } footer: {
                Text("Checked in the background on the watch itself — no iPhone needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Notify me about") {
                ForEach(NotificationSettingsStore.notifiableReasons, id: \.rawValue) { reason in
                    let meta = label(for: reason)
                    Toggle(isOn: Binding(
                        get: { store.isReasonEnabled(reason) },
                        set: { store.setReason(reason, enabled: $0); revision += 1 }
                    )) {
                        Label(meta.name, systemImage: meta.icon)
                    }
                    .disabled(!store.interactionsEnabled)
                }
            }

            Section {
                Button(role: .destructive) {
                    showSignOutConfirmation = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } footer: {
                if let handle = service.currentHandle {
                    Text("Signed in as @\(handle)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(
            "Sign out of \(service.currentHandle.map { "@\($0)" } ?? "this account")?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await service.logout() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
