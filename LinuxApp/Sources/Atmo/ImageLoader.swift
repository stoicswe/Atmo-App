import Adwaita
import CAdw
import Foundation
import FoundationNetworking

/// Async remote-image cache for the GTK front end. AtmoCore stays UI-free
/// (see PORTING.md), so avatar and embed bytes are fetched here: memory
/// first, then an XDG cache directory, then the network. Views read
/// `cached(_:)` synchronously in their body and call `request(_:)` for
/// anything missing; when a download lands, `onUpdate` fires (once per
/// batch) so the shell can bump its render tick.
@MainActor
final class ImageLoader {

    static let shared = ImageLoader()

    /// Set by MainView.onAppear — bumps the render tick.
    var onUpdate: (() -> Void)?

    private var memory: [URL: Data] = [:]
    private var inFlight: Set<URL> = []
    /// URLs that failed to download this session — retried on next launch,
    /// not in a loop.
    private var failed: Set<URL> = []
    private var updateScheduled = false

    private let diskDirectory: URL

    private init() {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
            .flatMap { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        diskDirectory = base.appendingPathComponent("atmo/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// The image bytes if already loaded (memory or disk); nil otherwise.
    func cached(_ url: URL?) -> Data? {
        guard let url else { return nil }
        if let data = memory[url] { return data }
        if let data = try? Data(contentsOf: diskPath(for: url)) {
            memory[url] = data
            return data
        }
        return nil
    }

    /// Starts a download unless the image is cached, in flight, or failed.
    func request(_ url: URL?) {
        guard let url,
              memory[url] == nil,
              !inFlight.contains(url),
              !failed.contains(url),
              !FileManager.default.fileExists(atPath: diskPath(for: url).path)
        else { return }
        inFlight.insert(url)
        Task { @MainActor in
            defer { inFlight.remove(url) }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    failed.insert(url)
                    return
                }
                memory[url] = data
                try? data.write(to: diskPath(for: url))
                scheduleUpdate()
            } catch {
                failed.insert(url)
            }
        }
    }

    /// Coalesces the re-render across downloads finishing in one runloop pass.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor in
            updateScheduled = false
            onUpdate?()
        }
    }

    private func diskPath(for url: URL) -> URL {
        // FNV-1a over the absolute string — cheap, and collisions across a
        // few hundred CDN URLs are not a realistic concern for a thumbnail
        // cache (worst case: a wrong picture until the cache is cleared).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return diskDirectory.appendingPathComponent(String(hash, radix: 16) + ".img")
    }
}

// MARK: - Remote image views

/// A round `AdwAvatar` that shows the author's image once downloaded and
/// initials meanwhile. The generated wrapper doesn't expose
/// `custom-image`, so the texture is installed through `.inspect`.
/// Nonisolated like every Adwaita view builder; GTK guarantees the main
/// thread, `onMain` restates it for the compiler.
func remoteAvatar(url: URL?, name: String, size: Int) -> AnyView {
    onMain { ImageLoader.shared.request(url) }
    return Avatar(showInitials: true, size: size)
        .text(name)
        .inspect { storage, _, updateProperties in
            guard updateProperties else { return }
            let key = "atmo.avatar.url"
            let urlString = url?.absoluteString
            guard storage.fields[key] as? String != urlString else { return }
            guard let data = onMain({ ImageLoader.shared.cached(url) }) else {
                // Row recycled to a new author whose image isn't here yet —
                // drop the old face so initials show, not someone else.
                if storage.fields[key] != nil {
                    adw_avatar_set_custom_image(storage.opaquePointer, nil)
                    storage.fields[key] = nil
                }
                return
            }
            let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, .init(data.count)) }
            let texture = gdk_texture_new_from_bytes(bytes, nil)
            g_bytes_unref(bytes)
            guard let texture else { return }
            adw_avatar_set_custom_image(storage.opaquePointer, texture)
            g_object_unref(UnsafeMutableRawPointer(texture))
            storage.fields[key] = urlString
        }
}

/// An embed thumbnail: the picture once downloaded, a placeholder meanwhile.
@ViewBuilder
func remotePicture(url: URL, maxHeight: Int) -> Body {
    let data = onMain { () -> Data? in
        ImageLoader.shared.request(url)
        return ImageLoader.shared.cached(url)
    }
    if let data {
        Picture(data: data)
            .canShrink()
            .contentFit(.scaleDown)
            .frame(maxHeight: maxHeight)
    } else {
        Text("· · ·")
            .style("dim-label")
            .padding(16)
            .style("card")
    }
}
