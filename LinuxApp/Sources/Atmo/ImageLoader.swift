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

    /// Downloads waiting for a slot. A fresh timeline requests ~50 images
    /// at once; corelibs-foundation's libcurl-backed URLSession is fragile
    /// under that many parallel tasks (see the _MultiHandle warnings), so
    /// only a few run concurrently.
    private var pending: [URL] = []
    private var activeDownloads = 0
    private static let maxConcurrentDownloads = 4

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

    /// Queues a download unless the image is cached, in flight, or failed.
    func request(_ url: URL?) {
        guard let url,
              memory[url] == nil,
              !inFlight.contains(url),
              !failed.contains(url),
              !FileManager.default.fileExists(atPath: diskPath(for: url).path)
        else { return }
        inFlight.insert(url)
        pending.append(url)
        pumpDownloads()
    }

    /// Starts queued downloads while slots are free.
    private func pumpDownloads() {
        while activeDownloads < Self.maxConcurrentDownloads, !pending.isEmpty {
            let url = pending.removeFirst()
            activeDownloads += 1
            Task { @MainActor in
                defer {
                    activeDownloads -= 1
                    inFlight.remove(url)
                    pumpDownloads()
                }
                do {
                    // Explicit timeout: a hung transfer would otherwise
                    // hold its slot forever and starve the whole queue
                    // (corelibs-foundation hands out 0-progress stalls
                    // under load more readily than Darwin).
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 20
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        FileHandle.standardError.write(Data("[img] non-200 \((response as? HTTPURLResponse)?.statusCode ?? -1) \(url)\n".utf8))
                        failed.insert(url)
                        return
                    }
                    memory[url] = data
                    try? data.write(to: diskPath(for: url))
                    scheduleUpdate()
                } catch {
                    FileHandle.standardError.write(Data("[img] error \(error) \(url)\n".utf8))
                    failed.insert(url)
                }
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

/// An embed thumbnail: an empty `GtkPicture` whose texture is installed
/// imperatively once the bytes arrive — the same `.inspect` pattern as
/// `remoteAvatar`. (A declarative branch swap — placeholder view ⇄
/// `Picture(data:)` — never materializes inside ForEach list rows in
/// this toolkit version, so the widget stays put and only its paintable
/// changes.)
func remotePicture(url: URL, maxHeight: Int) -> AnyView {
    onMain { ImageLoader.shared.request(url) }
    // inspect must precede .frame: frame wraps in a Clamp, and the
    // closure needs the Picture's own storage.
    return Picture()
        .canShrink()
        .contentFit(.scaleDown)
        .inspect { storage, _, updateProperties in
            guard updateProperties else { return }
            let key = "atmo.picture.url"
            let urlString = url.absoluteString
            guard storage.fields[key] as? String != urlString else { return }
            guard let data = onMain({ ImageLoader.shared.cached(url) }) else {
                // Row recycled to a post whose image isn't here yet —
                // clear the old picture rather than show the wrong one.
                if storage.fields[key] != nil {
                    gtk_picture_set_paintable(storage.opaquePointer, gdk_paintable_new_empty(0, 0))
                    storage.fields[key] = nil
                }
                return
            }
            let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, .init(data.count)) }
            let texture = gdk_texture_new_from_bytes(bytes, nil)
            g_bytes_unref(bytes)
            guard let texture else { return }
            gtk_picture_set_paintable(storage.opaquePointer, texture)
            // A can-shrink GtkPicture reports a 0 minimum and collapses
            // inside these list rows — request a concrete height derived
            // from the texture so layout can't flatten it.
            let height = min(Int32(maxHeight), gdk_texture_get_height(texture))
            gtk_widget_set_size_request(storage.opaquePointer?.cast(), -1, height)
            g_object_unref(UnsafeMutableRawPointer(texture))
            storage.fields[key] = urlString
        }
}
