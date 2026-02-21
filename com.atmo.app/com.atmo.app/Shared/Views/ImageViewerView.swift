import SwiftUI
import ATProtoKit

// MARK: - ImageViewerView
// Full-screen image viewer with paging (TabView), pinch-to-zoom, and double-tap-to-zoom.
// Presented as a sheet from ThreadView when the user taps any image in a post embed.
//
// Usage:
//   .sheet(isPresented: $showImageViewer) {
//       ImageViewerView(images: images, selectedIndex: $selectedImageIndex)
//   }
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
                    ZoomableImageView(url: images[index].fullSizeImageURL)
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
                            .background(Circle().fill(.ultraThinMaterial.opacity(0.85)))
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
                            .background(Circle().fill(.ultraThinMaterial.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIndex == images.count - 1)
                    .opacity(currentIndex == images.count - 1 ? 0.3 : 1)
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
            }
#endif

            // ── Dismiss button ──
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle()
                            .fill(.ultraThinMaterial.opacity(0.85))
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 56)
            .padding(.trailing, 20)

            // ── Image counter pill (e.g. "2 / 4") ──
            // Reads currentIndex (a @State copy) — not the Binding — to avoid
            // triggering a state mutation during the parent view's update pass.
            if images.count > 1 {
                Text("\(currentIndex + 1) / \(images.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(.ultraThinMaterial.opacity(0.75))
                    }
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
private struct ZoomableImageView: View {
    let url: URL?

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
                                    scale = min(maxScale, max(minScale, proposed))
                                }
                                .onEnded { _ in
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
            .background {
                RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.85))
            }
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
