import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Embedded Video Player
/// Inline HLS player for video embeds in feeds and threads, mirroring the
/// official Bluesky behavior:
///   • Muted by default, with a speaker toggle to bring sound in.
///   • Auto-plays once the view has sat mostly on screen for ~1 s of
///     scroll rest; scrolling again re-arms the timer.
///   • Pauses and releases the player (stream + decoder) once mostly
///     scrolled away, falling back to the poster frame.
///   • Loops.
///   • While a player is live, a bottom control strip carries play/pause,
///     elapsed time, a scrubbing bar (drag or tap to seek), the total
///     length, and the sound toggle. A manual pause sticks — the autoplay
///     timer won't overrule it until the video scrolls away and returns.
///
/// Visibility and scroll-rest detection are self-contained: the view
/// watches its own frame within the enclosing scroll view's bounds via
/// `onGeometryChange`, so it works in every scroll context (timeline,
/// thread, profile, search) without plumbing scroll state through them.
struct EmbeddedVideoPlayer: View {
    let playlistURL: URL
    let thumbnailURL: URL?

    @State private var model: EmbeddedPlayerModel? = nil

    var body: some View {
        ZStack {
            // Poster frame sits behind the player: visible until the stream
            // renders its first frame, and again after teardown.
            if let thumbnailURL {
                AsyncCachedImage(url: thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.black.opacity(0.4)
                    }
                }
            } else {
                Color.black.opacity(0.4)
            }

            if let player = model?.player {
                PlayerLayerView(player: player)
            }
        }
        .overlay {
            if let model, model.player != nil {
                // Live player, paused: the badge becomes a resume button.
                if !model.isPlaying, !model.isScrubbing {
                    Button {
                        Haptics.tap()
                        model.togglePlayPause()
                    } label: {
                        playBadge
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play video")
                    .transition(.opacity)
                }
            } else {
                // Poster state: non-interactive badge — a tap falls through
                // to the cell (open thread); autoplay handles playback.
                playBadge
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let model, model.player != nil {
                PlaybackControlsBar(model: model)
                    .padding(.horizontal, AtmoTheme.Spacing.sm)
                    .padding(.bottom, AtmoTheme.Spacing.sm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model?.isPlaying == true)
        .onGeometryChange(for: ViewportMetrics.self) { proxy in
            ViewportMetrics(
                frame: proxy.frame(in: .scrollView),
                container: proxy.bounds(of: .scrollView)
            )
        } action: { metrics in
            ensureModel().viewportChanged(metrics)
        }
        .onDisappear {
            model?.teardown()
        }
    }

    private var playBadge: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 48))
            .foregroundStyle(.white)
            .atmoShadow(AtmoTheme.Shadow.floating)
    }

    /// The model is created lazily on the first geometry event so cells the
    /// user flies past never allocate playback machinery.
    private func ensureModel() -> EmbeddedPlayerModel {
        if let model { return model }
        let created = EmbeddedPlayerModel(url: playlistURL)
        model = created
        return created
    }
}

// MARK: - Playback Controls Bar
// Bottom strip over the video: play/pause, elapsed time, the scrubber,
// total length, and the sound toggle. Dark scrim capsule so the white
// controls read over any footage. Every control handles its own touches,
// so taps on the strip never fall through to the cell's open-thread tap.
private struct PlaybackControlsBar: View {
    let model: EmbeddedPlayerModel

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            Button {
                Haptics.tap()
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "Pause video" : "Play video")

            Text(Self.timeString(model.currentTime))
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white)

            VideoScrubberBar(model: model)

            Text(Self.timeString(model.duration))
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))

            Button {
                Haptics.tap()
                model.toggleMute()
            } label: {
                Image(systemName: model.isMuted
                      ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isMuted ? "Unmute video" : "Mute video")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.black.opacity(0.45), in: Capsule())
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Scrubber Bar
// Draggable progress track. A drag (or tap — minimumDistance 0) claims the
// touch with high priority, so scrubbing never scrolls the feed or opens
// the thread. Seeks stream live while dragging (AVPlayer coalesces them),
// with one frame-accurate seek on release.
private struct VideoScrubberBar: View {
    let model: EmbeddedPlayerModel

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fraction = model.duration > 0
                ? min(max(model.currentTime / model.duration, 0), 1)
                : 0
            let thumbSize: CGFloat = model.isScrubbing ? 13 : 9

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(height: 3)
                Capsule()
                    .fill(.white)
                    .frame(width: fraction * width, height: 3)
                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: fraction * width - thumbSize / 2)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: model.isScrubbing)
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
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
        .accessibilityValue("\(PlaybackControlsBar.timeString(model.currentTime)) of \(PlaybackControlsBar.timeString(model.duration))")
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

// MARK: - Viewport Metrics
/// The view's frame and the enclosing scroll view's visible bounds, both
/// in the scroll view's coordinate space. `container` is nil outside any
/// scroll view — treated as fully visible.
///
/// `nonisolated`: onGeometryChange compares values off the main actor, so
/// the synthesized Equatable must not inherit the default MainActor.
private nonisolated struct ViewportMetrics: Equatable {
    var frame: CGRect
    var container: CGRect?
}

// MARK: - Player Model
@Observable
@MainActor
private final class EmbeddedPlayerModel {
    let url: URL

    private(set) var player: AVPlayer? = nil
    private(set) var isPlaying = false
    private(set) var isMuted = true
    /// Playhead position in seconds — periodic while playing, live while
    /// the user drags the scrubber.
    private(set) var currentTime: Double = 0
    /// Total length in seconds; 0 until the stream reports it.
    private(set) var duration: Double = 0
    /// The user's finger is on the scrubber — the periodic time observer
    /// yields to the drag position until release.
    private(set) var isScrubbing = false

    /// Fraction of the view currently inside the scroll viewport.
    @ObservationIgnored private var visibleFraction: CGFloat = 0
    /// Last vertical position relative to the viewport — movement here is
    /// what distinguishes "scrolling" from "resting".
    @ObservationIgnored private var lastAnchorY: CGFloat? = nil
    /// Pending "has the scroll rested long enough?" check.
    @ObservationIgnored private var idleTask: Task<Void, Never>? = nil
    @ObservationIgnored private var loopObserver: NSObjectProtocol? = nil
    @ObservationIgnored private var timeObserver: Any? = nil
    /// Plain stored copy of the player owning `timeObserver` — deinit is
    /// nonisolated and cannot read the @Observable `player` accessor.
    @ObservationIgnored private var timeObserverOwner: AVPlayer? = nil
    /// The user hit pause — autoplay must not overrule it. Cleared by
    /// pressing play and by teardown, so a video scrolled away and
    /// revisited auto-plays fresh like any other.
    @ObservationIgnored private var userPaused = false

    /// Play once the view rests at least this visible for `restDelay`.
    private static let playThreshold: CGFloat = 0.55
    /// Below this the stream is dropped entirely.
    private static let teardownThreshold: CGFloat = 0.15
    /// "Stopped scrolling for about a second."
    private static let restDelay: Duration = .milliseconds(950)

    init(url: URL) {
        self.url = url
    }

    func viewportChanged(_ metrics: ViewportMetrics) {
        let anchorY: CGFloat
        if let container = metrics.container {
            let intersection = metrics.frame.intersection(container)
            visibleFraction = metrics.frame.height > 0 && !intersection.isNull
                ? intersection.height / metrics.frame.height
                : 0
            // Position relative to the viewport moves during a scroll no
            // matter which space the named coordinates resolve to.
            anchorY = metrics.frame.minY - container.minY
        } else {
            visibleFraction = 1
            anchorY = metrics.frame.minY
        }

        if visibleFraction < Self.teardownThreshold {
            idleTask?.cancel()
            teardown()
            lastAnchorY = anchorY
            return
        }

        let moved = lastAnchorY.map { abs($0 - anchorY) > 2 } ?? true
        lastAnchorY = anchorY

        // Re-arm the rest timer on movement; also arm it on the first
        // sighting so videos already on screen at load start on their own.
        if moved || (!isPlaying && idleTask == nil) {
            scheduleRestCheck()
        }
    }

    private func scheduleRestCheck() {
        guard !userPaused else { return }
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

    private func startPlayback() {
        if player == nil {
            let item = AVPlayerItem(url: url)
            // Feed cells shouldn't buffer minutes ahead of a muted loop.
            item.preferredForwardBufferDuration = 5

            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = isMuted
            newPlayer.preventsDisplaySleepDuringVideoPlayback = false
            newPlayer.actionAtItemEnd = .none

            loopObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak newPlayer] _ in
                newPlayer?.seek(to: .zero)
                newPlayer?.play()
            }

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
        configureAudioSession(muted: isMuted)
        player?.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            userPaused = true
            idleTask?.cancel()
            idleTask = nil
        } else {
            userPaused = false
            configureAudioSession(muted: isMuted)
            player.play()
            isPlaying = true
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        configureAudioSession(muted: isMuted)
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
        defer { isScrubbing = false }
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
    func teardown() {
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
        self.player = nil
        isPlaying = false
        isScrubbing = false
        userPaused = false
        currentTime = 0
        duration = 0
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

// MARK: - Player Layer View
// Bare AVPlayerLayer host — AVKit's VideoPlayer insists on its own
// controls, which have no place on an inline auto-playing cell.
#if os(iOS)
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerUIView {
        PlayerContainerUIView()
    }

    func updateUIView(_ view: PlayerContainerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
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

    func makeNSView(context: Context) -> PlayerContainerNSView {
        PlayerContainerNSView()
    }

    func updateNSView(_ view: PlayerContainerNSView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
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
