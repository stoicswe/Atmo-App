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
    }

    private(set) var session: Session? = nil

    func present(
        _ images: [AppBskyLexicon.Embed.ImagesDefinition.ViewImage],
        at index: Int
    ) {
        guard !images.isEmpty else { return }
        session = Session(images: images, index: min(max(index, 0), images.count - 1))
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

    var body: some View {
        if let session = presenter.session {
            ZStack {
                backdrop
                pager(session: session)
                    .ignoresSafeArea()
            }
            .overlay { chrome(session: session) }
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
                    onPinchOut: { presenter.dismissViewer() }
                )
                .tag(index)
            }
        }
        // The glass counter pill replaces the system dots.
        .tabViewStyle(.page(indexDisplayMode: .never))
#else
        ZoomableImageView(url: session.images[safe: session.index]?.fullSizeImageURL ?? nil)
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
        return ZStack {
            saveButton(for: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(AtmoTheme.Spacing.md)

            closeButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(AtmoTheme.Spacing.md)

            if session.images.count > 1 {
                Text("\(session.index + 1) / \(session.images.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, AtmoTheme.Spacing.md)
            }

            if !image.altText.isEmpty {
                AltTextBadge(text: image.altText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(AtmoTheme.Spacing.md)
                    .padding(.bottom, session.images.count > 1 ? 32 : 0)
            }

#if os(macOS)
            if session.images.count > 1 {
                pagerArrow(symbol: "chevron.left", step: -1, session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(AtmoTheme.Spacing.md)
                pagerArrow(symbol: "chevron.right", step: 1, session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(AtmoTheme.Spacing.md)
            }
#endif
        }
    }

#if os(macOS)
    private func pagerArrow(
        symbol: String, step: Int, session: ImageViewerPresenter.Session
    ) -> some View {
        let target = session.index + step
        return Button {
            page(by: step, in: session)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .disabled(!session.images.indices.contains(target))
        .opacity(session.images.indices.contains(target) ? 1 : 0.3)
    }
#endif

    private var closeButton: some View {
        Button {
            presenter.dismissViewer()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Close image viewer")
    }

    private func saveButton(
        for image: AppBskyLexicon.Embed.ImagesDefinition.ViewImage
    ) -> some View {
        Button {
            guard saveState == .idle else { return }
            let url = image.fullSizeImageURL
            Haptics.tap()
            Task {
                saveState = .saving
                do {
                    try await MediaSaver.saveImage(from: url)
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
                        .tint(.white)
                case .saved:
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
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
    var onPinchOut: (() -> Void)? = nil

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

            AsyncCachedImage(url: url) { phase in
                if let image = phase.image {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reset zoom when the user swipes to a different page in the TabView
        .id(url)
        .onDisappear {
            scale = minScale
            lastScale = minScale
            offset = .zero
            lastOffset = .zero
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
                        .foregroundStyle(.white)

                    if expanded {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                if expanded {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 260, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
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
