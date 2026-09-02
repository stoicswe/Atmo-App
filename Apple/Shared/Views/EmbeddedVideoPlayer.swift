import SwiftUI
import AVFoundation
import AtmoCore
#if os(iOS)
import UIKit
import AVKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Embedded Video Player
/// Inline HLS player for video embeds in feeds and threads, mirroring the
/// official Bluesky behavior with native iOS 26-style controls:
///   • Muted by default; auto-plays once the view has sat mostly on screen
///     for ~1 s of scroll rest; scrolling again re-arms the timer. The
///     stream is opened (not started) the moment the cell is mostly on
///     screen, so the poster's play badge — a real button — and the rest
///     timer both start playback without a cold connect. A spinner sits
///     over the frame while the stream buffers its first segments.
///   • Pauses and releases the player (stream + decoder) once mostly
///     scrolled away, falling back to the poster frame.
///   • Loops.
///   • Controls are the system video-player layout in Liquid Glass: a
///     center cluster of skip-back-10 / play-pause / skip-forward-10, a
///     bottom time capsule with elapsed, a scrubbing track, and remaining
///     time, an expand button top-left, and the sound toggle top-right.
///     Tapping the video toggles the controls; they fade on their own a
///     few seconds into playback, exactly like the native player.
///   • The expand button opens full-screen playback (cover on iOS, a large
///     sheet on macOS) with the same glass controls at full size, an X to
///     close, and a volume slider capsule. Sound comes on for full screen
///     and the feed's mute state is restored on the way back.
///   • iOS / iPadOS: a Picture in Picture button (inline and full screen)
///     hands the stream to the system mini player, which keeps playing
///     while the person moves around the app or leaves it.
///   • Full screen offers "Original": swaps the HLS stream for the file the
///     author uploaded, served by their PDS (typically 1080p at its native
///     bitrate vs HLS's 720p cap), keeping the playhead. Remembered per
///     video; inline playback always goes back to HLS.
///
/// Visibility and scroll-rest detection are self-contained: the view
/// watches its own frame within the enclosing scroll view's bounds via
/// `onGeometryChange`, so it works in every scroll context (timeline,
/// thread, profile, search) without plumbing scroll state through them.
struct EmbeddedVideoPlayer: View {
    let playlistURL: URL
    let thumbnailURL: URL?
    /// Feed behaviour: play on scroll rest. Off for grid tiles, which only
    /// play when tapped.
    var autoplays: Bool = true
    /// Grid tiles: a tap on the running video toggles play/pause instead
    /// of showing the control layer.
    var tapTogglesPlayback: Bool = false
    /// Bump to open full screen from outside (a tile's context menu).
    var fullscreenRequest: Int = 0
    /// Hide the expand control (a detached window has nowhere to go).
    var showsExpandButton: Bool = true
    /// Sound on from the start (the detached window).
    var startsUnmuted: Bool = false
    /// Seek here once the stream is ready (carrying a playhead over).
    var startTime: Double = 0
    /// The video's pixel size from the post, handed to the detached window
    /// so it opens at that size and keeps the shape.
    var videoPixelSize: CGSize? = nil

#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#endif

    @State private var model: EmbeddedPlayerModel? = nil
    @State private var showFullscreen = false

    var body: some View {
        ZStack {
            // Poster frame sits behind the player: visible until the stream
            // renders its first frame, and again after teardown. Bound to
            // the box (Color.clear + overlay) so a tall poster can't grow
            // the player past its crop — which would push the centered
            // play badge and controls below the visible area.
            Color.clear
                .overlay {
                    if let thumbnailURL {
                        AsyncCachedImage(url: thumbnailURL, maxPixelSize: 1400) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.black.opacity(0.4)
                            }
                        }
                    } else {
                        Color.black.opacity(0.4)
                    }
                }
                .clipped()

            if let model, model.isActive, let player = model.player {
#if os(iOS)
                PlayerLayerView(player: player, pictureInPictureHost: model)
#else
                PlayerLayerView(player: player)
#endif
            }
        }
        .overlay {
            if let model, model.isActive {
                // Live player: a tap anywhere off the controls toggles them,
                // native-player style.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if tapTogglesPlayback {
                            model.togglePlayPause(showingControls: false)
                        } else {
                            model.toggleControls()
                        }
                    }
            } else {
                // Poster state: the whole video area is the play target, so
                // a tap anywhere on it plays right away instead of waiting
                // on the autoplay rest timer. A child tap gesture always
                // beats the cell's own tap-to-open-thread gesture, so the
                // post opens only from taps outside the video.
                playBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.tap()
                        ensureModel().playNow()
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Play video")
                    .transition(.opacity)
            }
        }
        .overlay {
            // Stream still buffering its first segments after play: keep
            // the person informed without putting the full controls up.
            if let model, model.isActive, model.isBuffering, !model.controlsVisible {
                bufferingSpinner
                    .transition(.opacity)
            }
        }
        .overlay {
            if let model, model.isActive, model.controlsVisible {
                VideoControlsOverlay(model: model, style: .inline, showsCorner: showsExpandButton, onCorner: {
                    expand(model)
                })
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Clean-playback state: a lone mini mute badge keeps sound one
            // tap away without the full control layer.
            if let model, model.isActive, !model.controlsVisible {
                Button {
                    Haptics.tap()
                    model.toggleMute()
                } label: {
                    Image(systemName: model.isMuted
                          ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .videoControlGlass(in: Circle())
                .padding(AtmoTheme.Spacing.sm)
                .transition(.opacity)
                .accessibilityLabel(model.isMuted ? "Unmute video" : "Mute video")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model?.controlsVisible == true)
        .animation(.easeInOut(duration: 0.15), value: model?.isActive == true)
        .animation(.easeInOut(duration: 0.2), value: model?.isBuffering == true)
        .onGeometryChange(for: ViewportMetrics.self) { proxy in
            ViewportMetrics(
                size: proxy.size,
                scrollOffsetY: proxy.frame(in: .scrollView).minY,
                container: proxy.bounds(of: .scrollView)
            )
        } action: { metrics in
            ensureModel().viewportChanged(metrics)
        }
        .onDisappear {
            model?.teardown()
        }
#if os(macOS)
        // Double-click pops the video out into its own window. Simultaneous
        // with the single-click handlers underneath (which just toggle the
        // controls twice, a no-op).
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if showsExpandButton { expand(ensureModel()) }
            }
        )
#endif
        .onChange(of: fullscreenRequest) { _, request in
            guard request > 0 else { return }
            let model = ensureModel()
            if !model.isActive { model.playNow() }
            model.enterFullscreen()
            showFullscreen = true
        }
#if os(iOS)
        .fullScreenCover(isPresented: $showFullscreen) {
            if let model {
                FullscreenVideoView(model: model)
            }
        }
#else
        .sheet(isPresented: $showFullscreen) {
            if let model {
                FullscreenVideoView(model: model)
                    .frame(minWidth: 780, minHeight: 460)
            }
        }
#endif
    }

    /// Expand: iOS covers the screen; macOS detaches the video into its
    /// own resizable window (a fresh player at the same playhead) and
    /// pauses the inline copy so two streams don't run.
    private func expand(_ model: EmbeddedPlayerModel) {
#if os(macOS)
        let request = VideoWindowRequest(
            playlistURL: playlistURL,
            thumbnailURL: thumbnailURL,
            pixelWidth: videoPixelSize.map { Int($0.width) },
            pixelHeight: videoPixelSize.map { Int($0.height) },
            startTime: model.currentTime
        )
        if model.isPlaying { model.togglePlayPause(showingControls: false) }
        openWindow(id: "video-player", value: request)
#else
        model.enterFullscreen()
        showFullscreen = true
#endif
    }

    private var playBadge: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 48))
            .foregroundStyle(.white)
            .atmoShadow(AtmoTheme.Shadow.floating)
    }

    private var bufferingSpinner: some View {
        ProgressView()
            .tint(.white)
            .frame(width: 48, height: 48)
            .videoControlGlass(in: Circle(), interactive: false)
            .allowsHitTesting(false)
    }

    /// The model is created lazily on the first geometry event so cells the
    /// user flies past never allocate playback machinery.
    private func ensureModel() -> EmbeddedPlayerModel {
        if let model { return model }
        let created = EmbeddedPlayerModel(
            url: playlistURL, autoplays: autoplays, startsMuted: !startsUnmuted, startTime: startTime
        )
        model = created
        return created
    }
}

// MARK: - Fullscreen Player
/// Full-screen playback with the same glass controls at full size: X to
/// close top-left, volume capsule top-right, the skip/play cluster center,
/// and the time-capsule scrubber along the bottom. Shares the inline
/// model's AVPlayer, so position, loop, and play state carry over both ways.
private struct FullscreenVideoView: View {
    let model: EmbeddedPlayerModel

    @Environment(\.dismiss) private var dismiss
    @State private var saveState: MediaSaveState = .idle
    @State private var showSaveError = false
    @State private var saveErrorText = ""

    var body: some View {
        content
#if os(iOS)
            .statusBarHidden(!model.controlsVisible)
#endif
    }

    private var content: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                PlayerLayerView(player: player, gravity: .resizeAspect)
                    .ignoresSafeArea()
            }
        }
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.toggleControls() }
                .ignoresSafeArea()
        }
        .overlay {
            if model.controlsVisible {
                VideoControlsOverlay(
                    model: model,
                    style: .fullscreen,
                    // Save to Photos, offered when the stream maps back to
                    // an original blob (every video.bsky.app playlist does).
                    saveState: VideoBlobLocator.parse(playlistURL: model.url) != nil
                        ? saveState : nil,
                    onSave: { saveVideo() },
                    onCorner: { dismiss() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
        .onAppear { model.showControls() }
        .onDisappear { model.exitFullscreen() }
        .alert("Couldn't Save", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorText)
        }
    }

    private func saveVideo() {
        guard saveState == .idle else { return }
        Haptics.tap()
        Task {
            saveState = .saving
            do {
                try await MediaSaver.saveVideo(fromPlaylist: model.url)
                Haptics.confirm()
                saveState = .saved
                try? await Task.sleep(for: .seconds(1.6))
            } catch {
                saveErrorText = error.localizedDescription
                showSaveError = true
            }
            saveState = .idle
        }
    }
}

// MARK: - Glass Controls Overlay
/// The native-style control layer, shared by the inline player and full
/// screen — same layout, two size classes. Every control handles its own
/// touches, so taps on them never fall through to toggle-controls or the
/// cell's open-thread tap.
private struct VideoControlsOverlay: View {
    enum Style { case inline, fullscreen }

    let model: EmbeddedPlayerModel
    let style: Style
    /// Inline only: whether the expand control is offered.
    var showsCorner: Bool = true
    /// Save-to-Photos affordance (fullscreen): non-nil shows the button in
    /// this state.
    var saveState: MediaSaveState? = nil
    var onSave: (() -> Void)? = nil
    /// Inline: expand to full screen. Fullscreen: close.
    let onCorner: () -> Void

    private var inline: Bool { style == .inline }

    var body: some View {
        centerCluster
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if !inline || showsCorner {
                    cornerButton
                        .padding(inline ? AtmoTheme.Spacing.sm : AtmoTheme.Spacing.lg)
                }
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: AtmoTheme.Spacing.sm) {
                    soundControl
                    if model.isPictureInPictureSupported {
                        pictureInPictureButton
                    }
                    if let saveState, let onSave {
                        saveButton(state: saveState, action: onSave)
                    }
                    if !inline, model.supportsOriginalQuality {
                        originalQualityButton
                    }
                }
                .padding(inline ? AtmoTheme.Spacing.sm : AtmoTheme.Spacing.lg)
            }
            .overlay(alignment: .bottom) {
                timeCapsule
                    .padding(.horizontal, inline ? AtmoTheme.Spacing.sm : AtmoTheme.Spacing.xl)
                    .padding(.bottom, inline ? AtmoTheme.Spacing.sm : AtmoTheme.Spacing.lg)
            }
    }

    // MARK: Center cluster — skip back / play-pause / skip forward

    private var centerCluster: some View {
        HStack(spacing: inline ? 20 : 36) {
            skipButton(seconds: -10, symbol: "gobackward.10")
            playPauseButton
            skipButton(seconds: 10, symbol: "goforward.10")
        }
    }

    private var playPauseButton: some View {
        Button {
            Haptics.tap()
            model.togglePlayPause()
        } label: {
            Group {
                if model.isPlaying, model.isBuffering {
                    ProgressView()
                        .tint(.white)
                        .controlSize(inline ? .regular : .large)
                } else {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: inline ? 18 : 28, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: inline ? 48 : 72, height: inline ? 48 : 72)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .videoControlGlass(in: Circle())
        .accessibilityLabel(model.isPlaying ? "Pause video" : "Play video")
    }

    private func skipButton(seconds: Double, symbol: String) -> some View {
        Button {
            Haptics.tap()
            model.skip(by: seconds)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: inline ? 14 : 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: inline ? 36 : 56, height: inline ? 36 : 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .videoControlGlass(in: Circle())
        .accessibilityLabel(seconds < 0 ? "Skip back 10 seconds" : "Skip forward 10 seconds")
    }

    // MARK: Corner button — expand (inline) / close (fullscreen)

    private var cornerButton: some View {
        Button {
            Haptics.tap()
            onCorner()
        } label: {
            Image(systemName: inline ? "arrow.up.left.and.arrow.down.right" : "xmark")
                .font(.system(size: inline ? 11 : 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: inline ? 30 : 40, height: inline ? 30 : 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .videoControlGlass(in: Circle())
        .accessibilityLabel(inline ? "Play full screen" : "Close full screen")
    }

    // MARK: Sound — mute toggle (inline) / volume capsule (fullscreen)

    @ViewBuilder
    private var soundControl: some View {
        if inline {
            muteButton(size: 30, iconSize: 12)
                .videoControlGlass(in: Circle())
        } else {
            HStack(spacing: 10) {
                VolumeSliderTrack(model: model)
                muteButton(size: 28, iconSize: 14)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .videoControlGlass(in: Capsule())
        }
    }

    /// Picture in Picture: hands the stream to the system mini player.
    /// From full screen the cover closes first so the inline layer — the
    /// one the controller is bound to — is back on screen.
    private var pictureInPictureButton: some View {
        Button {
            Haptics.tap()
#if os(iOS)
            if inline {
                model.startPictureInPicture()
            } else {
                onCorner()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    model.startPictureInPicture()
                }
            }
#endif
        } label: {
            Image(systemName: model.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                .font(.system(size: inline ? 12 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: inline ? 30 : 40, height: inline ? 30 : 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .videoControlGlass(in: Circle())
        .accessibilityLabel("Picture in Picture")
    }

    /// "Original": play the author's upload instead of HLS. Off → accent
    /// on; a spinner while the PDS is resolved; a note when it can't be.
    private var originalQualityButton: some View {
        Button {
            Haptics.tap()
            model.toggleOriginalQuality()
        } label: {
            HStack(spacing: 6) {
                if model.isSwitchingQuality {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: model.isOriginalQuality ? "checkmark.circle.fill" : "sparkles.tv")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(model.originalUnavailable ? "Original unavailable" : "Original")
                    .font(.caption.weight(.semibold))
                    .fixedSize()
            }
            .foregroundStyle(model.isOriginalQuality ? AtmoColors.accent : .white)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .videoControlGlass(in: Capsule())
        .disabled(model.isSwitchingQuality || model.originalUnavailable)
        .accessibilityLabel(model.isOriginalQuality ? "Playing original quality" : "Play original quality")
    }

    /// Save-to-Photos: idle glyph → spinner while the blob downloads →
    /// a brief checkmark.
    private func saveButton(state: MediaSaveState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                switch state {
                case .idle:
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                case .saving:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                case .saved:
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .videoControlGlass(in: Circle())
        .accessibilityLabel("Save video to Photos")
    }

    private func muteButton(size: CGFloat, iconSize: CGFloat) -> some View {
        Button {
            Haptics.tap()
            model.toggleMute()
        } label: {
            Image(systemName: model.isMuted
                  ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isMuted ? "Unmute video" : "Mute video")
    }

    // MARK: Bottom time capsule — elapsed · scrubber · remaining

    private var timeCapsule: some View {
        HStack(spacing: 10) {
            Text(VideoTimeFormat.string(model.currentTime))
                .font(inline ? .caption2.weight(.medium) : .footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white)

            VideoScrubberBar(model: model, trackHeight: inline ? 5 : 7)

            Text("-" + VideoTimeFormat.string(max(0, model.duration - model.currentTime)))
                .font(inline ? .caption2.weight(.medium) : .footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .frame(height: inline ? 32 : 40)
        .videoControlGlass(in: Capsule(), interactive: false)
    }
}

// MARK: - Volume Slider Track
// Fullscreen volume capsule's slider: drag to set the player's volume;
// dragging up from silence unmutes. The fill collapses while muted so the
// capsule reads the true audible state at a glance.
private struct VolumeSliderTrack: View {
    let model: EmbeddedPlayerModel

    private static let width: CGFloat = 84

    var body: some View {
        let effective = model.isMuted ? 0 : CGFloat(model.volume)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(height: 4)
            Capsule()
                .fill(.white)
                .frame(width: effective * Self.width, height: 4)
        }
        .frame(width: Self.width, height: 28)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.setVolume(Float(value.location.x / Self.width))
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((model.isMuted ? 0 : model.volume) * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step: Float = 0.1
            model.setVolume(model.volume + (direction == .increment ? step : -step))
        }
    }
}

// MARK: - Scrubber Bar
// Draggable progress track in the native style — a plain rounded bar that
// thickens under the finger, no thumb knob. A drag (or tap — minimumDistance
// 0) claims the touch with high priority, so scrubbing never scrolls the
// feed or opens the thread. Seeks stream live while dragging (AVPlayer
// coalesces them), with one frame-accurate seek on release.
private struct VideoScrubberBar: View {
    let model: EmbeddedPlayerModel
    var trackHeight: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fraction = model.duration > 0
                ? min(max(model.currentTime / model.duration, 0), 1)
                : 0
            let height = model.isScrubbing ? trackHeight + 3 : trackHeight

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: height)
                Capsule()
                    .fill(.white)
                    .frame(width: fraction * width, height: height)
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .animation(.easeInOut(duration: 0.15), value: model.isScrubbing)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.scrub(toFraction: value.location.x / width)
                    }
                    .onEnded { value in
                        model.endScrub(atFraction: value.location.x / width)
                    }
            )
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Video position")
        .accessibilityValue("\(VideoTimeFormat.string(model.currentTime)) of \(VideoTimeFormat.string(model.duration))")
        .accessibilityAdjustableAction { direction in
            let step: Double = 5
            let target = direction == .increment
                ? model.currentTime + step
                : model.currentTime - step
            guard model.duration > 0 else { return }
            model.endScrub(atFraction: target / model.duration)
        }
    }
}

// MARK: - Time Format
private enum VideoTimeFormat {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Control Glass
private extension View {
    /// Dark-tinted Liquid Glass — the system video-control look: refracts
    /// the footage behind it while keeping white glyphs legible over any
    /// frame.
    func videoControlGlass(in shape: some Shape, interactive: Bool = true) -> some View {
        glassEffect(
            interactive
                ? .regular.tint(.black.opacity(0.28)).interactive()
                : .regular.tint(.black.opacity(0.28)),
            in: shape
        )
    }
}

// MARK: - Viewport Metrics
/// What visibility is computed from:
///   • `size` — the view's own size (its bounds are `(0, 0, size)`).
///   • `container` — the enclosing scroll view's visible bounds, which
///     `GeometryProxy.bounds(of:)` returns *converted into this view's
///     local space* (its origin is the negative of the view's position in
///     the viewport). Nil outside any scroll view — treated as fully
///     visible. Intersecting it with the local bounds is the whole
///     visibility test; intersecting it with a frame in scroll-view space
///     (the earlier bug) counted the view's offset twice, so anything in
///     the lower half of the viewport read as off screen.
///   • `scrollOffsetY` — the view's position in the scroll view's space;
///     movement here is what distinguishes scrolling from resting.
///
/// `nonisolated`: onGeometryChange compares values off the main actor, so
/// the synthesized Equatable must not inherit the default MainActor.
private nonisolated struct ViewportMetrics: Equatable {
    var size: CGSize
    var scrollOffsetY: CGFloat
    var container: CGRect?
}

// MARK: - Player Model
@Observable
@MainActor
private final class EmbeddedPlayerModel {
    let url: URL

    /// Exists from the first mostly-visible sighting (pre-buffering) until
    /// teardown; check `isActive` for whether playback has begun.
    private(set) var player: AVPlayer? = nil
    /// Seek applied once, when playback first starts.
    @ObservationIgnored private var pendingStartTime: Double
    /// Playback has been started (by autoplay or the play badge) — the
    /// video layer and controls belong on screen. False while the player
    /// is merely warming the stream behind the poster.
    private(set) var isActive = false
    private(set) var isPlaying = false
    /// The player wants to play but is waiting on the stream (initial
    /// segments, a stall). Drives the spinner.
    private(set) var isBuffering = false
    private(set) var isMuted = true
    /// Player-level volume, driven by the fullscreen slider.
    private(set) var volume: Float = 1
    /// Playhead position in seconds — periodic while playing, live while
    /// the user drags the scrubber.
    private(set) var currentTime: Double = 0
    /// Total length in seconds; 0 until the stream reports it.
    private(set) var duration: Double = 0
    /// The user's finger is on the scrubber — the periodic time observer
    /// yields to the drag position until release.
    private(set) var isScrubbing = false
    /// The glass control layer is up. Shown when playback starts and on
    /// tap; fades a few seconds into playback, native-player style.
    private(set) var controlsVisible = false
    /// Full-screen presentation is up — the inline lifecycle must not tear
    /// the player down underneath it (covers fire onDisappear/zero-visible
    /// geometry on the covered feed).
    private(set) var isFullscreen = false
    /// The system Picture in Picture mini player is showing this video.
    private(set) var isPictureInPictureActive = false
#if os(iOS)
    @ObservationIgnored private var pipController: AVPictureInPictureController? = nil
    @ObservationIgnored private var pipDelegate: PictureInPictureDelegate? = nil
#endif
    /// Playing the author's original upload instead of the HLS stream.
    private(set) var isOriginalQuality = false
    private(set) var isSwitchingQuality = false
    /// The PDS declined (or the video isn't a Bluesky stream) — offered
    /// once, then the control explains itself.
    private(set) var originalUnavailable = false
    @ObservationIgnored private var originalBlobURL: URL? = nil

    /// Fraction of the view currently inside the scroll viewport.
    @ObservationIgnored private var visibleFraction: CGFloat = 0
    /// Last vertical position relative to the viewport — movement here is
    /// what distinguishes "scrolling" from "resting".
    @ObservationIgnored private var lastAnchorY: CGFloat? = nil
    /// Pending "has the scroll rested long enough?" check.
    @ObservationIgnored private var idleTask: Task<Void, Never>? = nil
    /// Pending controls fade-out.
    @ObservationIgnored private var hideControlsTask: Task<Void, Never>? = nil
    @ObservationIgnored private var loopObserver: NSObjectProtocol? = nil
    @ObservationIgnored private var statusObserver: NSKeyValueObservation? = nil
    @ObservationIgnored private var timeObserver: Any? = nil
    /// Plain stored copy of the player owning `timeObserver` — deinit is
    /// nonisolated and cannot read the @Observable `player` accessor.
    @ObservationIgnored private var timeObserverOwner: AVPlayer? = nil
    /// The user hit pause — autoplay must not overrule it. Cleared by
    /// pressing play and by teardown, so a video scrolled away and
    /// revisited auto-plays fresh like any other.
    @ObservationIgnored private var userPaused = false
    /// Mute state to restore when full screen closes — full screen brings
    /// sound in, the feed goes back to its etiquette.
    @ObservationIgnored private var mutedBeforeFullscreen = true

    /// Play once the view rests at least this visible for `restDelay`.
    private static let playThreshold: CGFloat = 0.55
    /// Below this the stream is dropped entirely.
    private static let teardownThreshold: CGFloat = 0.15
    /// "Stopped scrolling for about a second."
    private static let restDelay: Duration = .milliseconds(950)
    /// Inline rendition caps (see preparePlayer).
    private static let inlinePeakBitRate: Double = 1_500_000
    private static let inlineMaximumResolution = CGSize(width: 960, height: 960)
    /// How long the controls linger after playback starts or a touch.
    private static let controlsLinger: Duration = .seconds(3)

    /// Whether scroll rest starts playback (feeds) or only a tap does (grid).
    let autoplays: Bool

    init(url: URL, autoplays: Bool = true, startsMuted: Bool = true, startTime: Double = 0) {
        self.url = url
        self.autoplays = autoplays
        self.isMuted = startsMuted
        self.pendingStartTime = startTime
    }

    func viewportChanged(_ metrics: ViewportMetrics) {
        if let container = metrics.container {
            // Both rects in the view's local space: own bounds vs. viewport.
            let bounds = CGRect(origin: .zero, size: metrics.size)
            let intersection = bounds.intersection(container)
            visibleFraction = bounds.height > 0 && !intersection.isNull
                ? intersection.height / bounds.height
                : 0
        } else {
            visibleFraction = 1
        }
        let anchorY = metrics.scrollOffsetY

        if visibleFraction < Self.teardownThreshold {
            idleTask?.cancel()
            teardown()
            lastAnchorY = anchorY
            return
        }

        let moved = lastAnchorY.map { abs($0 - anchorY) > 2 } ?? true
        lastAnchorY = anchorY

        // Mostly on screen: open the stream now so the playlist and first
        // segments are in hand by the time autoplay or a tap asks for
        // them. Bounded by the teardown above, so it's only ever the
        // videos actually in view.
        if visibleFraction >= Self.playThreshold, player == nil {
            preparePlayer()
        }

        // Re-arm the rest timer on movement; also arm it on the first
        // sighting so videos already on screen at load start on their own.
        if moved || (!isPlaying && idleTask == nil) {
            scheduleRestCheck()
        }
    }

    /// Immediate playback from the poster's play badge: skips the rest
    /// timer and any earlier pause.
    func playNow() {
        idleTask?.cancel()
        idleTask = nil
        userPaused = false
        startPlayback()
    }

    private func scheduleRestCheck() {
        guard autoplays, !userPaused else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.restDelay)
            guard !Task.isCancelled, let self else { return }
            self.idleTask = nil
            guard self.visibleFraction >= Self.playThreshold,
                  !self.userPaused, !self.isScrubbing
            else { return }
            self.startPlayback()
        }
    }

    /// Creates the player and attaches the HLS item, which starts loading
    /// the playlist and initial segments straight away — without playing.
    private func preparePlayer() {
        guard player == nil else { return }
        let item = AVPlayerItem(url: url)
        // Feed cells shouldn't buffer minutes ahead of a muted loop.
        item.preferredForwardBufferDuration = 5
        // Inline: steer HLS to the 360p rendition (Bluesky offers 360p at
        // ~0.9 Mbps and 720p at ~3.2 Mbps). Starts faster, a fraction of
        // the data, and indistinguishable in a muted cell. Full screen
        // lifts both caps (enterFullscreen).
        item.preferredPeakBitRate = Self.inlinePeakBitRate
        item.preferredMaximumResolution = Self.inlineMaximumResolution

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isMuted
        newPlayer.volume = volume
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        newPlayer.actionAtItemEnd = .none

        // Buffering state for the spinner. KVO fires on AVFoundation's
        // queue; hop to main before touching observed state.
        statusObserver = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                self.isBuffering = waiting
            }
        }

        installLoopObserver(for: item, on: newPlayer)

        // Drives the elapsed label and the scrubber's fill.
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds
                if let item = self.player?.currentItem {
                    let length = item.duration.seconds
                    if length.isFinite, length > 0 { self.duration = length }
                }
            }
        }
        timeObserverOwner = newPlayer
        player = newPlayer
    }

    /// Loops the given item; re-installed whenever the item is swapped.
    private func installLoopObserver(for item: AVPlayerItem, on player: AVPlayer) {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }

    // MARK: Picture in Picture (iOS / iPadOS)

    var isPictureInPictureSupported: Bool {
#if os(iOS)
        AVPictureInPictureController.isPictureInPictureSupported()
#else
        false
#endif
    }

#if os(iOS)
    /// Binds the system controller to the inline layer once it exists.
    func attachPictureInPicture(to layer: AVPlayerLayer) {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let delegate = PictureInPictureDelegate(owner: self)
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = delegate
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
        pipDelegate = delegate
    }

    func startPictureInPicture() {
        guard let pipController, !pipController.isPictureInPictureActive else { return }
        if !isActive { playNow() }
        // The system player needs the playback category and the audio on.
        if isMuted { toggleMute() }
        configureAudioSession(muted: false)
        pipController.startPictureInPicture()
    }

    func stopPictureInPicture() {
        pipController?.stopPictureInPicture()
    }

    fileprivate func pictureInPictureChanged(active: Bool) {
        isPictureInPictureActive = active
        if active { controlsInteracted() }
    }
#endif

    // MARK: Original quality

    private static let originalPreferenceKey = "atmo.video.originalQuality"

    /// Videos the person chose Original for, remembered across launches
    /// (a bounded set of playlist URLs).
    private static var preferredOriginal: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: originalPreferenceKey) ?? []) }
        set {
            var list = Array(newValue)
            if list.count > 200 { list = Array(list.suffix(200)) }
            UserDefaults.standard.set(list, forKey: originalPreferenceKey)
        }
    }

    /// Whether this video can offer an original file at all.
    var supportsOriginalQuality: Bool {
        VideoBlobLocator.parse(playlistURL: url) != nil
    }

    func toggleOriginalQuality() {
        Task { await setOriginalQuality(!isOriginalQuality, remember: true) }
    }

    /// Swaps between the HLS stream and the original upload, keeping the
    /// playhead and play state. A failed resolution leaves HLS playing and
    /// marks the original unavailable.
    func setOriginalQuality(_ original: Bool, remember: Bool) async {
        guard player != nil, !isSwitchingQuality, original != isOriginalQuality else { return }
        isSwitchingQuality = true
        defer { isSwitchingQuality = false }

        let target: URL
        if original {
            // The PDS serves blobs without byte-range support, which
            // AVPlayer needs to stream an MP4 — so fetch the file to the
            // local cache first and play from disk (seeking works too).
            if originalBlobURL == nil {
                originalBlobURL = await OriginalVideoCache.localFile(forPlaylist: url)
            }
            guard let blob = originalBlobURL else {
                originalUnavailable = true
                return
            }
            target = blob
        } else {
            target = url
        }

        swapItem(to: target, capped: !original)
        isOriginalQuality = original
        if remember {
            var set = Self.preferredOriginal
            if original { set.insert(url.absoluteString) } else { set.remove(url.absoluteString) }
            Self.preferredOriginal = set
        }
        controlsInteracted()
    }

    private func swapItem(to target: URL, capped: Bool) {
        guard let player else { return }
        let resumeAt = player.currentTime()
        let wasPlaying = isPlaying
        let item = AVPlayerItem(url: target)
        item.preferredForwardBufferDuration = 5
        if capped, !isFullscreen {
            item.preferredPeakBitRate = Self.inlinePeakBitRate
            item.preferredMaximumResolution = Self.inlineMaximumResolution
        }
        player.replaceCurrentItem(with: item)
        installLoopObserver(for: item, on: player)
        player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        if wasPlaying { player.play() }
    }

    private func startPlayback() {
        preparePlayer()
        configureAudioSession(muted: isMuted)
        if pendingStartTime > 0 {
            let target = pendingStartTime
            pendingStartTime = 0
            currentTime = target
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }
        player?.play()
        isPlaying = true
        isActive = true
        // Autoplay starts clean — the glass controls appear on tap, not
        // over every video the scroll happens to rest on.
    }

    func togglePlayPause(showingControls: Bool = true) {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            userPaused = true
            idleTask?.cancel()
            idleTask = nil
            // Paused controls stay up — the fade guard checks isPlaying.
            if showingControls { showControls() } else { hideControls() }
        } else {
            userPaused = false
            configureAudioSession(muted: isMuted)
            player.play()
            isPlaying = true
            if showingControls { showControls() } else { hideControls() }
        }
    }

    func hideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = nil
        controlsVisible = false
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        configureAudioSession(muted: isMuted)
        controlsInteracted()
    }

    /// Fullscreen volume slider. Dragging up from silence unmutes.
    func setVolume(_ newValue: Float) {
        volume = min(max(newValue, 0), 1)
        player?.volume = volume
        if volume > 0, isMuted {
            isMuted = false
            player?.isMuted = false
            configureAudioSession(muted: false)
        }
        controlsInteracted()
    }

    /// Relative seek for the ±10 s buttons. Doesn't disturb play state.
    func skip(by seconds: Double) {
        guard let player else { return }
        var target = max(0, currentTime + seconds)
        if duration > 0 { target = min(target, max(0, duration - 0.1)) }
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        controlsInteracted()
    }

    // MARK: Controls visibility

    func toggleControls() {
        if controlsVisible {
            hideControlsTask?.cancel()
            hideControlsTask = nil
            controlsVisible = false
        } else {
            showControls()
        }
    }

    func showControls() {
        controlsVisible = true
        scheduleControlsHide()
    }

    /// Any control interaction keeps the layer up a while longer.
    func controlsInteracted() {
        guard controlsVisible else { return }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.controlsLinger)
            guard !Task.isCancelled, let self else { return }
            self.hideControlsTask = nil
            // Linger while paused or mid-scrub; fade only over playback.
            guard self.isPlaying, !self.isScrubbing else { return }
            self.controlsVisible = false
        }
    }

    // MARK: Fullscreen

    /// Full screen implies the user wants the video proper: sound comes on
    /// and the display stays awake. Play state carries over untouched.
    func enterFullscreen() {
        guard player != nil else { return }
        isFullscreen = true
        mutedBeforeFullscreen = isMuted
        if isMuted {
            isMuted = false
            player?.isMuted = false
        }
        configureAudioSession(muted: false)
        player?.preventsDisplaySleepDuringVideoPlayback = true
        // Full screen wants the best rendition available.
        player?.currentItem?.preferredPeakBitRate = 0
        player?.currentItem?.preferredMaximumResolution = .zero
        showControls()
        // The person asked for the original last time: bring it back.
        if Self.preferredOriginal.contains(url.absoluteString), !isOriginalQuality {
            Task { await setOriginalQuality(true, remember: false) }
        }
    }

    /// Back to the feed: restore mute etiquette; playback carries on.
    func exitFullscreen() {
        guard isFullscreen else { return }
        isFullscreen = false
        player?.preventsDisplaySleepDuringVideoPlayback = false
        // Inline is muted and small: HLS again, whatever full screen used.
        if isOriginalQuality {
            swapItem(to: url, capped: true)
            isOriginalQuality = false
        }
        player?.currentItem?.preferredPeakBitRate = Self.inlinePeakBitRate
        player?.currentItem?.preferredMaximumResolution = Self.inlineMaximumResolution
        if mutedBeforeFullscreen, !isMuted {
            isMuted = true
            player?.isMuted = true
        }
        configureAudioSession(muted: isMuted)
        showControls()
    }

    // MARK: Scrubbing

    /// Live drag: pin the playhead readout to the finger and stream seeks —
    /// AVPlayer cancels superseded seeks itself, so the video skims along.
    func scrub(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        isScrubbing = true
        let target = min(max(fraction, 0), 1) * duration
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Release: one frame-accurate seek, then hand the playhead back to
    /// the time observer. Playback state is untouched — a playing video
    /// keeps playing from the new point, a paused one stays paused there.
    func endScrub(atFraction fraction: Double) {
        defer {
            isScrubbing = false
            controlsInteracted()
        }
        guard let player, duration > 0 else { return }
        let target = min(max(fraction, 0), 1) * duration
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Stops playback and releases the stream. The poster frame takes over.
    /// A no-op while full screen holds the player — the covered feed fires
    /// disappear/zero-visibility events that must not kill the video.
    func teardown() {
        guard !isFullscreen, !isPictureInPictureActive else { return }
        guard let player else { return }
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        timeObserverOwner = nil
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        self.player = nil
        isActive = false
        isPlaying = false
        isBuffering = false
        isOriginalQuality = false
        isSwitchingQuality = false
        isScrubbing = false
        userPaused = false
        currentTime = 0
        duration = 0
        hideControlsTask?.cancel()
        hideControlsTask = nil
        controlsVisible = false
    }

    /// Muted autoplay must never interrupt the user's music — ambient +
    /// mixWithOthers. Unmuting switches to playback so sound survives the
    /// silent switch, still mixing rather than ducking everything out.
    private func configureAudioSession(muted: Bool) {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(muted ? .ambient : .playback, options: [.mixWithOthers])
#endif
    }

    deinit {
        if let timeObserver, let timeObserverOwner {
            timeObserverOwner.removeTimeObserver(timeObserver)
        }
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
    }
}

#if os(iOS)
/// Forwards the system controller's callbacks to the model. NSObject
/// because AVFoundation requires it; the model itself stays a plain
/// observable class.
private final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    weak var owner: EmbeddedPlayerModel?

    init(owner: EmbeddedPlayerModel) { self.owner = owner }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in owner?.pictureInPictureChanged(active: true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in owner?.pictureInPictureChanged(active: false) }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        Task { @MainActor in owner?.pictureInPictureChanged(active: false) }
    }
}
#endif

// MARK: - Player Layer View
// Bare AVPlayerLayer host — AVKit's VideoPlayer insists on its own
// controls, which have no place on an inline auto-playing cell. Inline
// fills the cell (aspect-fill); full screen letterboxes (aspect-fit).
#if os(iOS)
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    /// The inline host: its layer is the one Picture in Picture uses.
    var pictureInPictureHost: EmbeddedPlayerModel? = nil

    func makeUIView(context: Context) -> PlayerContainerUIView {
        PlayerContainerUIView()
    }

    func updateUIView(_ view: PlayerContainerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != gravity {
            view.playerLayer.videoGravity = gravity
        }
        pictureInPictureHost?.attachPictureInPicture(to: view.playerLayer)
    }
}

private final class PlayerContainerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
#elseif os(macOS)
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PlayerContainerNSView {
        PlayerContainerNSView()
    }

    func updateNSView(_ view: PlayerContainerNSView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != gravity {
            view.playerLayer.videoGravity = gravity
        }
    }
}

private final class PlayerContainerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        // No implicit animation racing the scroll while cells resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
#endif


// MARK: - Original Video Cache
/// Original uploads fetched for "Original" playback, kept in Caches by
/// blob CID so re-opening a video (or the remembered preference) doesn't
/// download it again. Bounded; the system may purge it anyway.
enum OriginalVideoCache {
    private static let limit = 12

    private static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("OriginalVideos", isDirectory: true)
    }

    /// The local MP4 for a playlist's original upload — cached, or
    /// downloaded from the author's PDS now. Nil when unavailable.
    static func localFile(forPlaylist playlist: URL) async -> URL? {
        guard let reference = VideoBlobLocator.parse(playlistURL: playlist) else { return nil }
        let fm = FileManager.default
        let file = directory.appendingPathComponent("\(reference.cid).mp4")
        if fm.fileExists(atPath: file.path) { return file }

        guard let blobURL = await VideoBlobLocator.resolveBlobURL(playlistURL: playlist),
              let (downloaded, response) = try? await URLSession.shared.download(from: blobURL),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: file)
            try fm.moveItem(at: downloaded, to: file)
        } catch {
            try? fm.removeItem(at: downloaded)
            return nil
        }
        prune()
        return file
    }

    /// Bytes on disk.
    static func totalBytes() -> Int64 {
        EnhancedImageStore.directoryBytes(directory)
    }

    /// Removes every cached original (Settings → Clear Caches).
    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > limit else { return }
        let dated = files.map { url -> (URL, Date) in
            ((url), (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(files.count - limit) {
            try? fm.removeItem(at: url)
        }
    }
}
