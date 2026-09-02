import SwiftUI
import AtmoCore
import ATProtoKit

// MARK: - Image Viewer Presenter
/// Window-level presenter for the glass image viewer. A host view (the app
/// root, plus any sheet that shows tappable images — a covered node cannot
/// float chrome above its cover) owns one via `.hostsImageViewer()`, which
/// injects it into the environment and renders the centered glass popup
/// over everything when a session is active.
@Observable
@MainActor
final class ImageViewerPresenter {
    struct Session: Identifiable {
        let id = UUID()
        let images: [AppBskyLexicon.Embed.ImagesDefinition.ViewImage]
        var index: Int
        /// The post the images belong to, when known — lets an Enhanced
        /// copy be kept with the post's bookmark or Vault entry.
        let postURI: String?
    }

    private(set) var session: Session? = nil

    func present(
        _ images: [AppBskyLexicon.Embed.ImagesDefinition.ViewImage],
        at index: Int,
        postURI: String? = nil
    ) {
        guard !images.isEmpty else { return }
        session = Session(images: images, index: min(max(index, 0), images.count - 1), postURI: postURI)
    }

    func dismissViewer() {
        session = nil
    }

    /// Moves the pager to `index` (clamped to the session's images).
    func setIndex(_ index: Int) {
        guard var session else { return }
        session.index = min(max(index, 0), session.images.count - 1)
        self.session = session
    }
}

// MARK: - Image Viewer Host
/// Mounts the glass image viewer over this subtree and exposes the
/// presenter through the environment. Apply at the app root, and ALSO to
/// the root of any sheet whose content shows tappable images (same rule as
/// InAppBrowserHost) — pass that sheet's own presenter so its taps target
/// the local overlay rather than the covered root one.
struct ImageViewerHost: ViewModifier {
    @State private var presenter: ImageViewerPresenter

    init(presenter: ImageViewerPresenter? = nil) {
        _presenter = State(initialValue: presenter ?? ImageViewerPresenter())
    }

    func body(content: Content) -> some View {
        content
            .environment(presenter)
            .overlay {
                ZStack {
                    if presenter.session != nil {
                        GlassImageViewer(presenter: presenter)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: presenter.session?.id)
            }
    }
}

extension View {
    /// Hosts the centered glass image viewer for this subtree.
    func hostsImageViewer(_ presenter: ImageViewerPresenter? = nil) -> some View {
        modifier(ImageViewerHost(presenter: presenter))
    }
}

// MARK: - Full-Bleed Image Viewer
/// The photo fills the space it's given — the whole screen on iOS, the
/// whole window on macOS — scaled to fit its long edge, never stretched,
/// on black. Chrome floats over it inside the safe area: save-to-Photos,
/// close, pager arrows (macOS), counter, alt text.
///
/// Dismiss: the X, Esc (macOS), a tap on the letterbox, a flick down
/// (iOS), or pinching out past the fitted size (iOS) — zooming in never
/// leaves the photo, only shrinking it below fit does.
private struct GlassImageViewer: View {
    let presenter: ImageViewerPresenter

    /// Drives the fade/scale-in on appear; removal is the host's fade.
    @State private var appeared = false
    @State private var saveState: MediaSaveState = .idle
    @State private var showSaveError = false
    @State private var saveErrorText = ""
    /// Enhanced (upscaled) bytes per image URL for this session — made
    /// here, or loaded from the enhanced-image cache.
    @State private var enhanced: [String: Data] = [:]
    @State private var isEnhancing = false
    @State private var enhanceFailed = false
    /// Brightness under the chrome, per image URL — drives glyph colors.
    @State private var luminance: [String: ImageLuminance.Sample] = [:]
    @State private var containerSize: CGSize = .zero

    var body: some View {
        if let session = presenter.session {
            ZStack {
                backdrop
                pager(session: session)
                    .ignoresSafeArea()
            }
            .overlay { chrome(session: session) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
            .task(id: "lum|\(session.id)|\(session.index)") {
                let image = session.images[safe: session.index] ?? session.images[0]
                let key = image.fullSizeImageURL.absoluteString
                guard luminance[key] == nil,
                      let sample = await ImageLuminance.sample(image.thumbnailImageURL)
                else { return }
                luminance[key] = sample
            }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.96)
            .onAppear {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    appeared = true
                }
            }
#if os(iOS)
            // Flick down to dismiss. Simultaneous, so it never steals the
            // pager's horizontal swipe or the zoom pan (which claims drags
            // while zoomed in).
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        if value.translation.height > 90,
                           value.translation.height > abs(value.translation.width) {
                            presenter.dismissViewer()
                        }
                    }
            )
#endif
            .background {
                // Hidden keyboard handlers: Esc closes, arrows page (macOS).
                Group {
                    Button("") { presenter.dismissViewer() }
                        .keyboardShortcut(.cancelAction)
#if os(macOS)
                    Button("") { page(by: -1, in: session) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { page(by: 1, in: session) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
#endif
                }
                .opacity(0)
                .allowsHitTesting(false)
            }
            .alert("Couldn't Save", isPresented: $showSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveErrorText)
            }
            // A previously Enhanced copy (bookmarked / Vault / recent) is
            // shown straight away. Vault copies stay hidden while locked.
            .task(id: "\(session.id)|\(session.index)|\(EnhancedImageStore.shared.generation)") {
                let image = session.images[safe: session.index] ?? session.images[0]
                let key = image.fullSizeImageURL.absoluteString
                guard enhanced[key] == nil,
                      let file = EnhancedImageStore.shared.fileURL(for: image.fullSizeImageURL),
                      let data = try? Data(contentsOf: file)
                else { return }
                enhanced[key] = data
            }
        }
    }

    // MARK: Backdrop — black, edge to edge; the letterbox dismisses on tap

    private var backdrop: some View {
        Color.black
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { presenter.dismissViewer() }
    }

    // MARK: Pager — fills the container; each page fits its photo inside

    @ViewBuilder
    private func pager(session: ImageViewerPresenter.Session) -> some View {
#if os(iOS)
        TabView(selection: indexBinding(fallback: session.index)) {
            ForEach(session.images.indices, id: \.self) { index in
                ZoomableImageView(
                    url: session.images[index].fullSizeImageURL,
                    overrideData: enhanced[session.images[index].fullSizeImageURL.absoluteString],
                    onPinchOut: { presenter.dismissViewer() }
                )
                .tag(index)
            }
        }
        // The glass counter pill replaces the system dots.
        .tabViewStyle(.page(indexDisplayMode: .never))
#else
        ZoomableImageView(
            url: session.images[safe: session.index]?.fullSizeImageURL ?? nil,
            overrideData: session.images[safe: session.index].flatMap { enhanced[$0.fullSizeImageURL.absoluteString] }
        )
            .id(session.index)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: session.index)
#endif
    }

    private func indexBinding(fallback: Int) -> Binding<Int> {
        Binding(
            get: { presenter.session?.index ?? fallback },
            set: { presenter.setIndex($0) }
        )
    }

    private func page(by step: Int, in session: ImageViewerPresenter.Session) {
        let target = session.index + step
        guard session.images.indices.contains(target) else { return }
        presenter.setIndex(target)
    }

    // MARK: Chrome — floats inside the safe area; empty space passes taps through

    private func chrome(session: ImageViewerPresenter.Session) -> some View {
        let image = session.images[safe: session.index] ?? session.images[0]
        let key = image.fullSizeImageURL.absoluteString
        let topLight = bandIsLight(.top, image: image)
        let bottomLight = bandIsLight(.bottom, image: image)
        return ZStack {
            // Action pill: Save and Enhance share one glass capsule, the
            // iOS 26 toolbar grouping, instead of two separate discs.
            HStack(spacing: 0) {
                saveButton(for: image, onLight: topLight)
                Rectangle()
                    .fill(ChromeStyle.glyph(onLight: topLight).opacity(0.18))
                    .frame(width: 1, height: 18)
                enhanceButton(for: image, onLight: topLight)
            }
            .padding(.horizontal, 4)
            .glassEffect(ChromeStyle.glass(onLight: topLight, interactive: true), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(AtmoTheme.Spacing.md)
            .environment(\.chromeOnLight, topLight)

            if enhanced[key] != nil {
                Label("Enhanced", systemImage: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ChromeStyle.glyph(onLight: topLight))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(ChromeStyle.glass(onLight: topLight), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(AtmoTheme.Spacing.md)
                    .padding(.trailing, 44)
                    .allowsHitTesting(false)
            }

            closeButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(AtmoTheme.Spacing.md)
                .environment(\.chromeOnLight, topLight)

            if session.images.count > 1 {
                Text("\(session.index + 1) / \(session.images.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ChromeStyle.glyph(onLight: bottomLight))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(ChromeStyle.glass(onLight: bottomLight), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, AtmoTheme.Spacing.md)
            }

            if !image.altText.isEmpty {
                AltTextBadge(text: image.altText, onLight: bottomLight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(AtmoTheme.Spacing.md)
                    .padding(.bottom, session.images.count > 1 ? 32 : 0)
            }

#if os(macOS)
            if session.images.count > 1 {
                // Side arrows sit mid-height: average of the two bands.
                let midLight = topLight == bottomLight ? topLight : false
                pagerArrow(symbol: "chevron.left", step: -1, session: session, onLight: midLight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(AtmoTheme.Spacing.md)
                pagerArrow(symbol: "chevron.right", step: 1, session: session, onLight: midLight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(AtmoTheme.Spacing.md)
            }
#endif
        }
        .animation(.easeInOut(duration: 0.25), value: topLight)
        .animation(.easeInOut(duration: 0.25), value: bottomLight)
    }

    private enum Band { case top, bottom }

    /// Whether the chrome band sits over a light part of the picture. A
    /// band the fitted photo doesn't reach is over the black backdrop, so
    /// it counts as dark no matter how bright the photo is.
    private func bandIsLight(_ band: Band, image: AppBskyLexicon.Embed.ImagesDefinition.ViewImage) -> Bool {
        guard let sample = luminance[image.fullSizeImageURL.absoluteString] else { return false }
        if containerSize.width > 0, containerSize.height > 0,
           let ratio = image.aspectRatio, ratio.width > 0, ratio.height > 0 {
            let aspect = CGFloat(ratio.width) / CGFloat(ratio.height)
            let fittedHeight = min(containerSize.height, containerSize.width / aspect)
            let letterbox = (containerSize.height - fittedHeight) / 2
            // The chrome lives in the outer ~70 pt; if the photo starts
            // below that, the button is on black.
            if letterbox > 70 { return false }
        }
        let value = band == .top ? sample.top : sample.bottom
        return value > ChromeStyle.lightThreshold
    }

#if os(macOS)
    private func pagerArrow(
        symbol: String, step: Int, session: ImageViewerPresenter.Session, onLight: Bool
    ) -> some View {
        let target = session.index + step
        return Button {
            page(by: step, in: session)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(ChromeStyle.glyph(onLight: onLight))
                .chromeContrast(onLight: onLight)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(ChromeStyle.glass(onLight: onLight, interactive: true), in: Circle())
        .disabled(!session.images.indices.contains(target))
        .opacity(session.images.indices.contains(target) ? 1 : 0.3)
    }
#endif

    private var closeButton: some View {
        ChromeCircleButton(systemImage: "xmark", weight: .bold, label: "Close image viewer") {
            presenter.dismissViewer()
        }
    }

    /// Enhance: fetch the largest CDN preset and upscale toward 4K; the
    /// result replaces the displayed image, is what Save writes out, and
    /// is cached — for as long as the post stays bookmarked (or in the
    /// Vault), briefly otherwise.
    private func enhanceButton(
        for image: AppBskyLexicon.Embed.ImagesDefinition.ViewImage, onLight: Bool
    ) -> some View {
        let key = image.fullSizeImageURL.absoluteString
        let done = enhanced[key] != nil
        return Button {
            guard !isEnhancing, !done else { return }
            Haptics.tap()
            enhanceFailed = false
            Task {
                isEnhancing = true
                defer { isEnhancing = false }
                do {
                    let data = try await ImageEnhancer.enhance(image.fullSizeImageURL)
                    enhanced[key] = data
                    EnhancedImageStore.shared.store(data, for: image.fullSizeImageURL, postURI: presenter.session?.postURI)
                    Haptics.confirm()
                } catch {
                    enhanceFailed = true
                }
            }
        } label: {
            Group {
                if isEnhancing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: done ? "sparkles" : "wand.and.sparkles")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(done ? AtmoColors.accent : ChromeStyle.glyph(onLight: onLight))
            .chromeContrast(onLight: onLight)
            .frame(width: 40, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEnhancing || done)
        .help(done ? "Enhanced" : "Enhance")
        .accessibilityLabel(done ? "Enhanced" : "Enhance image")
        .overlay(alignment: .bottom) {
            if enhanceFailed {
                Text("Couldn't enhance")
                    .font(.caption2)
                    .foregroundStyle(ChromeStyle.glyph(onLight: onLight))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassEffect(.regular, in: Capsule())
                    .offset(y: 30)
                    .fixedSize()
            }
        }
    }

    private func saveButton(
        for image: AppBskyLexicon.Embed.ImagesDefinition.ViewImage, onLight: Bool
    ) -> some View {
        Button {
            guard saveState == .idle else { return }
            let url = image.fullSizeImageURL
            let enhancedData = enhanced[url.absoluteString]
            Haptics.tap()
            Task {
                saveState = .saving
                do {
                    // Enhanced first: that's the picture on screen.
                    if let enhancedData {
                        try await MediaSaver.saveImage(data: enhancedData)
                    } else {
                        try await MediaSaver.saveImage(from: url)
                    }
                    Haptics.confirm()
                    saveState = .saved
                    try? await Task.sleep(for: .seconds(1.6))
                } catch {
                    saveErrorText = error.localizedDescription
                    showSaveError = true
                }
                saveState = .idle
            }
        } label: {
            Group {
                switch saveState {
                case .idle:
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                case .saving:
                    ProgressView()
                        .controlSize(.small)
                        .tint(ChromeStyle.glyph(onLight: onLight))
                case .saved:
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(ChromeStyle.glyph(onLight: onLight))
            .chromeContrast(onLight: onLight)
            .frame(width: 40, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save image to Photos")
    }
}

// MARK: - ImageViewerView (legacy sheet)
// Full-screen sheet viewer, kept as the fallback for contexts without a
// `hostsImageViewer()` ancestor. New code should present through
// ImageViewerPresenter instead — that's the centered glass popup.
struct ImageViewerView: View {
    let images: [AppBskyLexicon.Embed.ImagesDefinition.ViewImage]
    @Binding var selectedIndex: Int
    @Environment(\.dismiss) private var dismiss

    // Separate state for the displayed page index so that the counter/alt-text
    // overlay reads from @State (not from the Binding directly), avoiding the
    // "modifying state during view update" warning that fires when TabView writes
    // back to selectedIndex while the body is still evaluating.
    @State private var currentIndex: Int = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Black backdrop — images look best on true black
            Color.black.ignoresSafeArea()

#if os(iOS)
            // iOS: paged TabView with swipe navigation
            TabView(selection: $currentIndex) {
                ForEach(images.indices, id: \.self) { index in
                    ZoomableImageView(
                        url: images[index].fullSizeImageURL,
                        onPinchOut: { dismiss() }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .always : .never))
            .ignoresSafeArea()
#else
            // macOS: simple pager — show one image at a time with arrow buttons
            ZoomableImageView(url: images[safe: currentIndex]?.fullSizeImageURL ?? nil)
                .ignoresSafeArea()

            // Prev / Next arrow buttons
            if images.count > 1 {
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentIndex = max(0, currentIndex - 1)
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIndex == 0)
                    .opacity(currentIndex == 0 ? 0.3 : 1)

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentIndex = min(images.count - 1, currentIndex + 1)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIndex == images.count - 1)
                    .opacity(currentIndex == images.count - 1 ? 0.3 : 1)
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
            }
#endif

#if os(iOS)
            // ── Top bar: gradient scrim, grabber, and a dismiss hint that
            // fades in and out occasionally. The sheet itself handles the
            // actual slide-down-to-dismiss.
            DismissHintBar()
#else
            // ── macOS: keep an explicit close button (no slide gesture). ──
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 56)
            .padding(.trailing, 20)
#endif

            // ── Image counter pill (e.g. "2 / 4") ──
            // Reads currentIndex (a @State copy) — not the Binding — to avoid
            // triggering a state mutation during the parent view's update pass.
            if images.count > 1 {
                Text("\(currentIndex + 1) / \(images.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 44)
            }

            // ── Alt text pill (shown when the image has alt text) ──
            if let alt = images[safe: currentIndex]?.altText, !alt.isEmpty {
                AltTextBadge(text: alt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.bottom, images.count > 1 ? 80 : 44)
                    .padding(.leading, 20)
            }
        }
        // Sync currentIndex from the incoming binding on first appear,
        // then keep it up to date as the TabView selection changes.
        .onAppear { currentIndex = selectedIndex }
        .onChange(of: currentIndex) { _, newValue in selectedIndex = newValue }
#if os(iOS)
        .presentationBackground(.black)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
#endif
    }
}

// MARK: - Zoomable Image View
// Wraps a single image with pinch-to-zoom (MagnificationGesture) and
// double-tap-to-zoom. Resets zoom when swiped away in the parent TabView.
// With `onPinchOut` set, pinching the photo smaller than its fitted size
// shrinks it live and, released a little past fit, dismisses the viewer;
// released just under fit it springs back.
private struct ZoomableImageView: View {
    let url: URL?
    /// Enhanced bytes to show instead of the URL's image, when present.
    var overrideData: Data? = nil
    var onPinchOut: (() -> Void)? = nil
    /// Decoded `overrideData`, off the main actor.
    @State private var overrideImage: Image? = nil

    /// Released below this fraction of fit → dismiss.
    private let dismissScale: CGFloat = 0.85
    /// How small the live pinch may render before it stops shrinking.
    private let pinchFloor: CGFloat = 0.45

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0
    private let doubleTapZoom: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width > 0 && geo.size.height > 0
                ? geo.size
                : CGSize(width: 400, height: 500)

            if let overrideImage {
                zoomable(overrideImage, size: size)
            } else {
            AsyncCachedImage(url: url) { phase in
                if let image = phase.image {
                    zoomable(image, size: size)
                } else if phase.error != nil {
                    // Failed to load
                    VStack(spacing: 12) {
                        Image(systemName: "photo.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Image unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: size.width, height: size.height)
                } else {
                    // Loading placeholder
                    ProgressView()
                        .tint(.white)
                        .frame(width: size.width, height: size.height)
                }
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reset zoom when the user swipes to a different page in the TabView
        .id(url)
        .task(id: overrideData?.count ?? 0) {
            guard let overrideData else { overrideImage = nil; return }
            let decoded = await Task.detached(priority: .userInitiated) {
                AsyncCachedImage<EmptyView>.decode(overrideData, maxPixelSize: nil)
            }.value
            guard let decoded else { return }
            #if canImport(UIKit)
            overrideImage = Image(uiImage: decoded)
            #else
            overrideImage = Image(nsImage: decoded)
            #endif
        }
        .onDisappear {
            scale = minScale
            lastScale = minScale
            offset = .zero
            lastOffset = .zero
        }
    }

    /// The image with fit sizing, pinch-zoom, pan, and double-tap — shared
    /// by the network image and an Enhanced override.
    private func zoomable(_ image: Image, size: CGSize) -> some View {
            image
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .offset(offset)
                // ── Pinch-to-zoom ──
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let proposed = lastScale * value
                            let floor = onPinchOut != nil ? pinchFloor : minScale
                            scale = min(maxScale, max(floor, proposed))
                        }
                        .onEnded { _ in
                            // Pinched out past fit: leave the viewer.
                            if scale < dismissScale, let onPinchOut {
                                onPinchOut()
                                return
                            }
                            lastScale = scale
                            // Snap back to 1× if pinched below minimum
                            if scale < minScale {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                    scale = minScale
                                    offset = .zero
                                }
                                lastScale = minScale
                                lastOffset = .zero
                            }
                        }
                )
                // ── Pan while zoomed ──
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            let maxX = (size.width  * (scale - 1)) / 2
                            let maxY = (size.height * (scale - 1)) / 2
                            offset = CGSize(
                                width:  (lastOffset.width  + value.translation.width).clamped(to: -maxX...maxX),
                                height: (lastOffset.height + value.translation.height).clamped(to: -maxY...maxY)
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                // ── Double-tap to zoom / reset ──
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        if scale > 1 {
                            scale = minScale
                            lastScale = minScale
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = doubleTapZoom
                            lastScale = doubleTapZoom
                        }
                    }
                }
    }
}

// MARK: - Dismiss Hint Bar
// A soft gradient along the viewer's top edge with a grabber pill, plus
// "Slide down to dismiss" pulsing in and out on a gentle cycle — enough
// to teach the gesture without permanent chrome over the photo.
private struct DismissHintBar: View {
    @State private var hintVisible = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 110)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            VStack(spacing: 10) {
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: 38, height: 5)
                Text("Slide down to dismiss")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .opacity(hintVisible ? 1 : 0)
            }
            .padding(.top, 12)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Fade in, hold, fade out, rest — repeating while the viewer
            // is open, so the hint reads as ambient rather than nagging.
            try? await Task.sleep(for: .milliseconds(600))
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.6)) { hintVisible = true }
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.easeInOut(duration: 0.8)) { hintVisible = false }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

// MARK: - Alt Text Badge
private struct AltTextBadge: View {
    let text: String
    var onLight: Bool = false
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                expanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("ALT")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(ChromeStyle.glyph(onLight: onLight))

                    if expanded {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(ChromeStyle.glyph(onLight: onLight).opacity(0.7))
                    }
                }

                if expanded {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(ChromeStyle.glyph(onLight: onLight))
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 260, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(ChromeStyle.glass(onLight: onLight), in: RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Content-aware chrome
/// Viewer chrome colors chosen from the photo underneath: white glyphs on
/// a faintly darkened glass over dark areas, near-black glyphs on clear
/// glass over light areas — so the buttons never wash out.
enum ChromeStyle {
    static func glyph(onLight: Bool) -> Color {
        onLight ? Color.black.opacity(0.82) : .white
    }

    /// Luminance above this reads as "light" under the chrome.
    static let lightThreshold = 0.55

    static func glass(onLight: Bool, interactive: Bool = false) -> Glass {
        let base: Glass = onLight ? .regular.tint(.white.opacity(0.35)) : .regular.tint(.black.opacity(0.22))
        return interactive ? base.interactive() : base
    }
}

extension View {
    /// A faint opposing halo behind a glyph, so it stays readable even in
    /// the moment before the photo's brightness has been sampled.
    func chromeContrast(onLight: Bool) -> some View {
        shadow(color: onLight ? .white.opacity(0.6) : .black.opacity(0.55), radius: 1.5)
    }
}

private struct ChromeOnLightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chromeOnLight: Bool {
        get { self[ChromeOnLightKey.self] }
        set { self[ChromeOnLightKey.self] = newValue }
    }
}

/// A round glass chrome button that reads `chromeOnLight`.
private struct ChromeCircleButton: View {
    let systemImage: String
    var weight: Font.Weight = .semibold
    let label: String
    let action: () -> Void

    @Environment(\.chromeOnLight) private var onLight

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: weight))
                .foregroundStyle(ChromeStyle.glyph(onLight: onLight))
                .chromeContrast(onLight: onLight)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(ChromeStyle.glass(onLight: onLight, interactive: true), in: Circle())
        .accessibilityLabel(label)
    }
}

// MARK: - Helpers

private extension Collection {
    /// Safe subscript — returns nil instead of crashing for out-of-bounds indices.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
