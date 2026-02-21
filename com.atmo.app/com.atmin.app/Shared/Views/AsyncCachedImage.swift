import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A URLCache-backed async image view. Provides a phase-based content builder
/// identical to SwiftUI's `AsyncImage` but with URLCache disk caching.
///
/// Uses a `loadID` UUID (rather than the URL itself) as the `.task` identity so
/// that the load task re-fires when a `LazyVStack` cell is recycled off-screen and
/// back on-screen — even if the URL hasn't changed and the previous task was
/// cancelled mid-flight. Without this, cells re-entering the viewport can get
/// stuck on `.empty` forever.
struct AsyncCachedImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty
    /// Bumped on `.onAppear` when the image hasn't loaded yet, forcing the
    /// `.task(id:)` to restart after LazyVStack task cancellation.
    @State private var loadID: UUID = UUID()

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(phase)
            // Re-run the load task whenever `loadID` changes (URL change or
            // forced re-fire on appearance).
            .task(id: loadID) {
                await loadImage()
            }
            .onAppear {
                // If the image loaded successfully, do nothing.
                if case .success = phase { return }
                // Defer the state write to the next run-loop tick so it doesn't
                // fire during the layout pass — avoids the SwiftUI "modifying
                // state during view update" runtime warning.
                // This handles two cases:
                //   1. First appearance — task hasn't run yet.
                //   2. LazyVStack recycle — task was cancelled; phase is still
                //      .empty but `.task(id: loadID)` won't re-fire unless we
                //      give it a new identity.
                Task { @MainActor in
                    loadID = UUID()
                }
            }
            .onChange(of: url) {
                // URL changed (e.g. a different post scrolled into the same
                // cell slot) — reset phase and trigger a fresh load.
                phase = .empty
                loadID = UUID()
            }
    }

    @MainActor
    private func loadImage() async {
        guard let url = url else {
            phase = .empty
            return
        }

        // Don't clobber a successfully-loaded image with a redundant re-fire.
        if case .success = phase { return }

        phase = .empty

        do {
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
            let (data, _) = try await URLSession.cachedSession.data(for: request)

            // If this task was cancelled while waiting for the network/cache,
            // bail out rather than writing stale state.
            guard !Task.isCancelled else { return }

            #if canImport(UIKit)
            if let uiImage = UIImage(data: data) {
                phase = .success(Image(uiImage: uiImage))
            } else {
                phase = .failure(URLError(.cannotDecodeContentData))
            }
            #elseif canImport(AppKit)
            if let nsImage = NSImage(data: data) {
                phase = .success(Image(nsImage: nsImage))
            } else {
                phase = .failure(URLError(.cannotDecodeContentData))
            }
            #endif
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
        }
    }
}

// MARK: - URLSession with caching
private extension URLSession {
    static let cachedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = .shared
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()
}

// URLCache configuration — set in AtmoApp.init() or app delegate
extension URLCache {
    static func configureSharedCache() {
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,   // 50 MB memory
            diskCapacity: 200 * 1024 * 1024,     // 200 MB disk
            diskPath: "atmo_image_cache"
        )
    }
}
