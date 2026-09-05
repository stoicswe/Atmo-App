import SwiftUI
import AtmoCore
#if os(macOS)
import AppKit
#endif

// MARK: - Detached Video Window (macOS)
/// What the inline player hands to `openWindow` when its expand button is
/// pressed (or the video is double-clicked) on macOS: enough to rebuild
/// the stream in its own window, picking up from the current playhead.
struct VideoWindowRequest: Codable, Hashable {
    let playlistURL: URL
    let thumbnailURL: URL?
    /// The video's pixel dimensions from the post, when known — the
    /// window opens at exactly this size (capped to the screen) and keeps
    /// the shape while resizing.
    let pixelWidth: Int?
    let pixelHeight: Int?
    let startTime: Double

    var aspectRatio: CGFloat {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

#if os(macOS)
/// A separate window playing one video edge to edge: opened at the
/// video's own dimensions, shape-locked so resizing never letterboxes,
/// content running under a transparent title bar, sound on, full glass
/// controls. Its own player, so the feed's inline (muted) one is untouched.
struct DetachedVideoWindow: View {
    let request: VideoWindowRequest

    /// Opening size: the video's pixels as points, shrunk to fit 90% of
    /// the screen, and never smaller than a usable minimum.
    private var initialSize: CGSize {
        let aspect = request.aspectRatio
        var width = CGFloat(request.pixelWidth ?? 960)
        var height = CGFloat(request.pixelHeight ?? 540)
        if request.pixelWidth == nil || request.pixelHeight == nil {
            width = 960
            height = 960 / aspect
        }
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxWidth = screen.width * 0.9
        let maxHeight = screen.height * 0.9
        let scale = min(1, maxWidth / width, maxHeight / height)
        width *= scale
        height *= scale
        let minWidth: CGFloat = 320
        if width < minWidth {
            width = minWidth
            height = minWidth / aspect
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    var body: some View {
        let size = initialSize
        ZStack {
            Color.black
            EmbeddedVideoPlayer(
                playlistURL: request.playlistURL,
                thumbnailURL: request.thumbnailURL,
                autoplays: true,
                showsExpandButton: false,
                startsUnmuted: true,
                startTime: request.startTime
            )
        }
        .ignoresSafeArea()
        .frame(
            minWidth: 320, idealWidth: size.width, maxWidth: .infinity,
            minHeight: 320 / request.aspectRatio, idealHeight: size.height, maxHeight: .infinity
        )
        .background(VideoWindowConfigurator(aspectRatio: request.aspectRatio, initialSize: size))
        .navigationTitle("Video")
    }
}

/// Reaches the hosting NSWindow to lock its aspect ratio to the video,
/// open it at the video's size, and run the content under the title bar
/// so the picture is edge to edge (traffic lights stay).
private struct VideoWindowConfigurator: NSViewRepresentable {
    let aspectRatio: CGFloat
    let initialSize: CGSize

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.aspectRatio = aspectRatio
        view.initialSize = initialSize
        return view
    }

    func updateNSView(_ view: ConfiguratorView, context: Context) {
        view.aspectRatio = aspectRatio
        view.initialSize = initialSize
        view.configureIfNeeded()
    }

    final class ConfiguratorView: NSView {
        var aspectRatio: CGFloat = 16.0 / 9.0
        var initialSize: CGSize = CGSize(width: 960, height: 540)
        private var configured = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureIfNeeded()
        }

        func configureIfNeeded() {
            guard !configured, let window else { return }
            configured = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            window.contentAspectRatio = NSSize(width: aspectRatio, height: 1)
            window.setContentSize(NSSize(width: initialSize.width, height: initialSize.height))
            window.center()
        }
    }
}
#endif
