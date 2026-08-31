import SwiftUI
import AtmoCore

// MARK: - In-App Browser
// iOS: web links open inside the app in an SFSafariViewController (Reader,
// share sheet, content blockers, and "open in Safari" included) instead of
// bouncing the user out to Safari. macOS keeps the platform convention of
// opening the default browser.

#if os(iOS)
import SafariServices

private struct InAppBrowserItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        controller.preferredControlTintColor = UIColor(AtmoColors.accent)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            dismiss()
        }
    }
}
#endif

/// Routes every `openURL` in the subtree through the in-app browser (iOS).
/// Apply to the app root, and ALSO to the root of any sheet whose content
/// contains web links — a presentation hosted behind an active sheet cannot
/// present, so sheets need their own local host.
struct InAppBrowserHost: ViewModifier {
#if os(iOS)
    @State private var item: InAppBrowserItem? = nil
    @State private var showLinkBlockedAlert = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $item) { item in
                SafariView(url: item.url)
                    .ignoresSafeArea()
            }
            .alert("Links Are Off", isPresented: $showLinkBlockedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Opening links is managed by your Family settings.")
            }
            .environment(\.openURL, OpenURLAction { url in
                // SFSafariViewController accepts only web URLs; everything
                // else (mailto:, app schemes) keeps the system behavior.
                guard let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else { return .systemAction }
                // Family controls: a managed child account may have link
                // browsing turned off entirely.
                guard ParentalControlsStore.shared.active.allowsLinkBrowsing else {
                    showLinkBlockedAlert = true
                    return .handled
                }
                item = InAppBrowserItem(url: url)
                return .handled
            })
    }
#else
    func body(content: Content) -> some View { content }
#endif
}

extension View {
    /// Opens web links tapped in this subtree in the in-app browser on iOS.
    func hostsInAppBrowser() -> some View {
        modifier(InAppBrowserHost())
    }
}
