import SwiftUI
#if os(iOS)
import UIKit

// MARK: - Orientation Lock (iPhone)
/// The iPhone app is portrait everywhere except the full-screen photo
/// viewer and full-screen video, which may turn sideways. The app delegate
/// answers UIKit's orientation query from `mask`; the viewers widen it on
/// appear and, on disappear, restore portrait and ask the scene to rotate
/// back so the app never sits sideways. iPad is unaffected (all
/// orientations, as before).
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// What the iPhone may rotate to right now.
    static var mask: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? Self.mask : .all
    }
}

enum OrientationLock {
    /// Let the current screen turn sideways (full-screen media).
    @MainActor
    static func allowLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        AppDelegate.mask = .allButUpsideDown
        refresh()
    }

    /// Back to portrait, rotating the scene if it's currently sideways.
    @MainActor
    static func restorePortrait() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        AppDelegate.mask = .portrait
        refresh()
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }

    @MainActor
    private static func refresh() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

/// Applies the media orientation rule for the lifetime of a view.
private struct AllowsLandscapeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { OrientationLock.allowLandscape() }
            .onDisappear { OrientationLock.restorePortrait() }
    }
}

extension View {
    /// Full-screen media: lets the iPhone rotate while this is on screen.
    func allowsLandscapeWhileVisible() -> some View {
        modifier(AllowsLandscapeModifier())
    }
}
#else
extension View {
    func allowsLandscapeWhileVisible() -> some View { self }
}
#endif
