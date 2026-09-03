import SwiftUI
#if os(iOS)
import UIKit

// MARK: - Full-Screen Media Presentation (iOS / iPadOS)
/// Full-screen photos and video are presented the UIKit way: a hosting
/// controller of their own, shown over the whole app. That — rather than a
/// SwiftUI overlay or a `.fullScreenCover` hung off a feed row — is what
/// makes rotating the phone safe:
///
/// • Orientation is answered from the presentation itself. The app
///   delegate lets the iPhone turn sideways only while a
///   `MediaViewerController` is up and not on its way out, and the
///   controller says the same from `supportedInterfaceOrientations`. UIKit
///   rotates the interface as the controller comes and goes, exactly as it
///   does for any landscape-capable modal — nothing rides on SwiftUI
///   appear/disappear timing, which fires spuriously during rotation.
/// • The presentation's lifetime belongs to the presenter object, not to
///   the view that asked for it. A `.fullScreenCover` presented from a
///   lazy feed row dies with the row, and rotating the phone re-lays out
///   the covered feed underneath, which releases rows — that was the
///   "video flips back to the feed on rotation" bug.
/// • The rest of the app never has to survive landscape: it turns under an
///   opaque presentation and is back in portrait before the media is gone.
///
/// iPad keeps every orientation everywhere, as before.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        return MediaViewerController.landscapeAllowed ? .allButUpsideDown : .portrait
    }
}

/// Hosts one full-screen media view over everything currently on screen
/// (including any sheet), full-bleed and cross-dissolved. Create it with
/// `present(onDismissed:content:)`; close it with `dismissMedia()`.
@MainActor
final class MediaViewerController: UIHostingController<AnyView> {
    /// Presentations currently live. An entry leaves the moment its
    /// dismissal begins, so the iPhone is portrait-only again — and UIKit
    /// turns it back — while the media fades out, not after.
    private static var live = Set<ObjectIdentifier>()

    /// Whether the iPhone may be sideways right now.
    static var landscapeAllowed: Bool { !live.isEmpty }

    private var onDismissed: ((MediaViewerController) -> Void)?
    private var finished = false
    /// Dismissal has begun (or completed): the controller is on its way
    /// out and a new presentation may take its place.
    private(set) var isClosing = false

    private init() {
        super.init(rootView: AnyView(EmptyView()))
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        // The hosted view (not the app underneath) decides the status bar.
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("MediaViewerController is code-only")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The media views paint their own black; nothing must show through
        // the cross-dissolve but them.
        view.backgroundColor = .clear
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? .allButUpsideDown : .all
    }

    /// Presents `content` over the top-most view controller of the active
    /// scene. The content receives the controller so it can close itself.
    /// `onDismissed` runs once the presentation is fully gone — however it
    /// went (our `dismissMedia()`, or torn down with a presenter beneath) —
    /// and receives the controller so a caller can tell it from a
    /// successor it has since put up.
    @discardableResult
    static func present<Content: View>(
        onDismissed: ((MediaViewerController) -> Void)? = nil,
        @ViewBuilder content: (MediaViewerController) -> Content
    ) -> MediaViewerController? {
        guard let presenter = topMostViewController() else { return nil }
        let controller = MediaViewerController()
        // The app's appearance, accent, text size and reduce-motion
        // settings — a hosting controller inherits no SwiftUI environment.
        controller.rootView = AnyView(content(controller).atmoTheme())
        controller.onDismissed = onDismissed
        live.insert(ObjectIdentifier(controller))
        presenter.present(controller, animated: true)
        return controller
    }

    /// Fades the media out; the iPhone turns back to portrait with it.
    func dismissMedia() {
        guard !isClosing else { return }
        isClosing = true
        Self.live.remove(ObjectIdentifier(self))
        dismiss(animated: true) { [weak self] in self?.finish() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Gone for good (not merely covered by an alert): tidy up, also
        // when something beneath us dismissed the whole modal stack.
        if isBeingDismissed || presentingViewController == nil {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        isClosing = true
        Self.live.remove(ObjectIdentifier(self))
        Self.restorePortraitIfNeeded()
        let callback = onDismissed
        onDismissed = nil
        callback?(self)
    }

    /// Belt and braces after a dismissal: UIKit normally rotates back on its
    /// own once the top-most controller is portrait-only again; if the
    /// scene is still sideways, ask it to turn.
    private static func restorePortraitIfNeeded() {
        guard UIDevice.current.userInterfaceIdiom == .phone, live.isEmpty else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if scene.effectiveGeometry.interfaceOrientation.isLandscape {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }

    /// The controller to present from: the deepest presented controller of
    /// the foreground scene's key window (so a viewer opened from inside a
    /// sheet lands above the sheet).
    private static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
#endif
