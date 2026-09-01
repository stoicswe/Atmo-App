import SwiftUI
import ImageIO
import AtmoCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - GIF Embed
/// Inline, looping GIF for link embeds that point at a GIF (see
/// `GIFLink`). The poster — Bluesky's cached thumbnail — shows while the
/// bytes download; once the payload is verified as a real GIF it plays
/// on a loop. Anything else (a `.gif` URL serving HTML or WebP, a failed
/// download) hands back to `fallback`, the ordinary link card.
///
/// Tapping toggles pause, like the official client. Reduce Motion starts
/// the GIF paused on its first frame with a play badge.
struct GIFEmbedView<Fallback: View>: View {
    let link: GIFLink
    let thumbnailURL: URL?
    var altText: String? = nil
    var sensitiveMedia: Bool = false
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: LoadState = .loading
    @State private var isPaused = false
    /// Same recycle-safe reload identity as AsyncCachedImage.
    @State private var loadID = UUID()

    private enum LoadState {
        case loading
        /// Verified GIF bytes and their width/height ratio.
        case ready(Data, CGFloat)
        case failed
    }

    var body: some View {
        switch state {
        case .failed:
            fallback()
        case .loading, .ready:
            media
        }
    }

    private var aspectRatio: CGFloat {
        let raw: CGFloat
        if let known = link.aspectRatio {
            raw = CGFloat(known)
        } else if case .ready(_, let measured) = state {
            raw = measured
        } else {
            raw = 1.5
        }
        // Same clamp as feed images: tall GIFs crop rather than tower.
        return min(max(raw, 0.85), 3.0)
    }

    private var media: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let thumbnailURL {
                    AsyncCachedImage(url: thumbnailURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .overlay {
                if case .ready(let data, _) = state {
                    AnimatedGIFView(data: data, isAnimating: !isPaused)
                }
            }
            .overlay {
                if case .loading = state {
                    ProgressView()
                        .tint(.white)
                        .padding(10)
                        .background(.black.opacity(0.35), in: Circle())
                }
            }
            .overlay {
                if isPaused {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white)
                        .atmoShadow(AtmoTheme.Shadow.floating)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text("GIF")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(8)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: 480)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                guard case .ready = state else { return }
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.15)) { isPaused.toggle() }
            }
            .sensitiveMediaShield(sensitiveMedia, key: link.mediaURL.absoluteString)
            .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
            .accessibilityLabel(altText?.isEmpty == false ? "GIF: \(altText!)" : "GIF")
            .accessibilityAddTraits(.isButton)
            .task(id: loadID) { await load() }
            .onAppear {
                if case .ready = state { return }
                Task { @MainActor in loadID = UUID() }
            }
            .onChange(of: link) {
                state = .loading
                loadID = UUID()
            }
    }

    @MainActor
    private func load() async {
        if case .ready = state { return }
        do {
            let request = URLRequest(url: link.mediaURL, cachePolicy: .returnCacheDataElseLoad)
            let (data, _) = try await URLSession.cachedSession.data(for: request)
            guard !Task.isCancelled else { return }
            // The URL said GIF; the bytes get the final say.
            guard GIFLink.isGIFData(data) else {
                state = .failed
                return
            }
            let ratio = await Task.detached(priority: .userInitiated) {
                GIFFrameSource.aspectRatio(of: data)
            }.value
            guard !Task.isCancelled else { return }
            isPaused = reduceMotion
            state = .ready(data, ratio ?? 1.5)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
        }
    }
}

// MARK: - Frame Source
/// ImageIO wrapper over a GIF's frames: count, per-frame delays, and
/// on-demand decoding. Frames aren't cached across loops (ImageIO's own
/// cache is off) — a feed GIF re-decodes in well under a frame interval,
/// and that keeps a long GIF from pinning tens of megabytes per cell.
final class GIFFrameSource {
    private let source: CGImageSource
    let frameCount: Int
    /// Seconds each frame is on screen. Sub-20 ms delays are bumped to
    /// 100 ms, the browser convention GIFs are authored against.
    let delays: [TimeInterval]

    init?(data: Data) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        self.source = source
        let count = CGImageSourceGetCount(source)
        frameCount = count
        delays = (0..<count).map { index in
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
            let delay = unclamped ?? clamped ?? 0.1
            return delay < 0.02 ? 0.1 : delay
        }
    }

    func frame(at index: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, index, options)
    }

    /// Width / height of the first frame, for reserving the box when the
    /// link carried no dimensions.
    static func aspectRatio(of data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0
        else { return nil }
        return CGFloat(width / height)
    }
}

// MARK: - Animated GIF View
/// Hosts a layer that steps through the GIF's frames on their own
/// delays and loops forever, whatever loop count the file declares.
/// `isAnimating` false freezes on the current frame.
#if os(iOS)
private struct AnimatedGIFView: UIViewRepresentable {
    let data: Data
    let isAnimating: Bool

    func makeUIView(context: Context) -> GIFPlayerView { GIFPlayerView() }

    func updateUIView(_ view: GIFPlayerView, context: Context) {
        view.configure(data: data, animating: isAnimating)
    }

    static func dismantleUIView(_ view: GIFPlayerView, coordinator: ()) {
        view.stop()
    }
}
#elseif os(macOS)
private struct AnimatedGIFView: NSViewRepresentable {
    let data: Data
    let isAnimating: Bool

    func makeNSView(context: Context) -> GIFPlayerView { GIFPlayerView() }

    func updateNSView(_ view: GIFPlayerView, context: Context) {
        view.configure(data: data, animating: isAnimating)
    }

    static func dismantleNSView(_ view: GIFPlayerView, coordinator: ()) {
        view.stop()
    }
}
#endif

#if os(iOS)
private typealias GIFHostView = UIView
#elseif os(macOS)
private typealias GIFHostView = NSView
#endif

private final class GIFPlayerView: GIFHostView {
    private var frames: GIFFrameSource? = nil
    private var dataIdentity: (count: Int, hash: Int)? = nil
    private var frameIndex = 0
    private var timer: Timer? = nil

    private var contentLayer: CALayer {
#if os(iOS)
        layer
#else
        layer!
#endif
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
#if os(macOS)
        // Layer-hosting: the layer is ours to draw into.
        let hosted = CALayer()
        layer = hosted
        wantsLayer = true
#endif
        contentLayer.contentsGravity = .resizeAspectFill
        contentLayer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

#if os(macOS)
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        contentLayer.contentsScale = window?.backingScaleFactor ?? 1
    }
#endif

    func configure(data: Data, animating: Bool) {
        let identity = (count: data.count, hash: data.hashValue)
        if dataIdentity == nil || dataIdentity! != identity {
            stop()
            dataIdentity = identity
            frames = GIFFrameSource(data: data)
            frameIndex = 0
            show(frame: 0)
        }
        if animating {
            start()
        } else {
            pause()
        }
    }

    private func start() {
        guard timer == nil, let frames, frames.frameCount > 1 else { return }
        scheduleNext(after: frames.delays[frameIndex])
    }

    /// Freeze on the current frame.
    private func pause() {
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        frames = nil
        dataIdentity = nil
    }

    private func scheduleNext(after delay: TimeInterval) {
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            self.advance()
        }
        next.tolerance = delay * 0.1
        // .common keeps the loop running while the feed scrolls.
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func advance() {
        guard let frames else { return }
        frameIndex = (frameIndex + 1) % frames.frameCount
        show(frame: frameIndex)
        scheduleNext(after: frames.delays[frameIndex])
    }

    private func show(frame index: Int) {
        guard let image = frames?.frame(at: index) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = image
        CATransaction.commit()
    }
}
