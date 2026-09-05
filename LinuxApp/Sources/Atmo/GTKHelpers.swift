import Adwaita
import CAdw
import Foundation
import AtmoCore

// GTK-side plumbing the Adwaita wrapper doesn't expose: opening URLs,
// the clipboard, the style manager, and two raw GObject signal hooks
// (`activate-link` on labels, position-aware `edge-reached` on scrolled
// windows). Nothing here touches AtmoCore state.

enum Desktop {

    /// Makes the app icon (`com.stoicswe.atmo`) resolvable when running
    /// from a source checkout: the snap installs it into the icon theme,
    /// a `swift build` binary has only `LinuxApp/dev-icons` next to it.
    static func installDevIconPath() {
        guard let display = gdk_display_get_default() else { return }
        let theme = gtk_icon_theme_get_for_display(display)
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("dev-icons")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("hicolor").path) {
                gtk_icon_theme_add_search_path(theme, candidate.path)
                return
            }
            directory.deleteLastPathComponent()
        }
    }

    /// Opens a URL with the default handler (the browser for http/https).
    static func open(_ url: URL) {
        gtk_show_uri(nil, url.absoluteString, 0)
    }

    static func open(_ string: String) {
        if let url = URL(string: string) { open(url) }
    }

    /// Puts text on the system clipboard.
    static func copy(_ text: String) {
        guard let display = gdk_display_get_default(),
              let clipboard = gdk_display_get_clipboard(display) else { return }
        gdk_clipboard_set_text(clipboard, text)
    }

    /// GNOME's system/light/dark switch, persisted like the Apple app's
    /// appearance setting (a Linux-only key; Apple stores its own).
    enum ColorScheme: String, CaseIterable, Identifiable, CustomStringConvertible {
        case system, light, dark

        static let storageKey = "atmo.linux.colorScheme"

        var id: String { rawValue }
        var description: String {
            switch self {
            case .system: return "Follow System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        static var current: ColorScheme {
            UserDefaults.standard.string(forKey: storageKey).flatMap(ColorScheme.init(rawValue:)) ?? .system
        }

        func apply() {
            UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
            let scheme: AdwColorScheme
            switch self {
            case .system: scheme = ADW_COLOR_SCHEME_DEFAULT
            case .light: scheme = ADW_COLOR_SCHEME_FORCE_LIGHT
            case .dark: scheme = ADW_COLOR_SCHEME_FORCE_DARK
            }
            adw_style_manager_set_color_scheme(adw_style_manager_get_default(), scheme)
        }
    }
}

/// Distinguishes a click on a link inside a post from a click on the post
/// body: GTK fires the label's `activate-link` and the row's click gesture
/// for the same press, so the row handler ignores a click that landed
/// within a beat of a link activation.
enum LinkClickGuard {
    nonisolated(unsafe) private static var lastLinkActivation: Date = .distantPast

    static func noteLinkActivation() { lastLinkActivation = Date() }

    static var shouldSwallowRowClick: Bool {
        Date().timeIntervalSince(lastLinkActivation) < 0.4
    }
}

// MARK: - Raw signal hooks

private final class LinkHandlerBox {
    var handler: (String) -> Bool
    init(_ handler: @escaping (String) -> Bool) { self.handler = handler }
}

private final class EdgeHandlerBox {
    var handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}

extension AnyView {

    /// Routes a markup label's link activations to `handler`. Return true
    /// to consume the link (in-app navigation); false lets GTK open the
    /// URI with the default handler.
    func onActivateLink(_ handler: @escaping (String) -> Bool) -> AnyView {
        inspect { storage, _, _ in
            let key = "atmo.link.handler"
            if let box = storage.fields[key] as? LinkHandlerBox {
                box.handler = handler
                return
            }
            let box = LinkHandlerBox(handler)
            storage.fields[key] = box
            let callback: @convention(c) (
                UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
            ) -> gboolean = { _, uri, data in
                guard let uri, let data else { return 0 }
                let box = Unmanaged<LinkHandlerBox>.fromOpaque(data).takeUnretainedValue()
                LinkClickGuard.noteLinkActivation()
                return box.handler(String(cString: uri)) ? 1 : 0
            }
            g_signal_connect_data(
                UnsafeMutableRawPointer(storage.opaquePointer),
                "activate-link",
                unsafeBitCast(callback, to: GCallback.self),
                Unmanaged.passUnretained(box).toOpaque(),
                nil,
                GConnectFlags(rawValue: 0)
            )
        }
    }

    /// Fires when a scrolled window hits its *bottom* edge — the
    /// generated `edgeReached` can't tell edges apart, which made it
    /// useless for paging (see PORTING.md).
    func onBottomEdgeReached(_ handler: @escaping () -> Void) -> AnyView {
        inspect { storage, _, _ in
            let key = "atmo.edge.handler"
            if let box = storage.fields[key] as? EdgeHandlerBox {
                box.handler = handler
                return
            }
            let box = EdgeHandlerBox(handler)
            storage.fields[key] = box
            let callback: @convention(c) (
                UnsafeMutableRawPointer?, GtkPositionType, UnsafeMutableRawPointer?
            ) -> Void = { _, position, data in
                guard position == GTK_POS_BOTTOM, let data else { return }
                Unmanaged<EdgeHandlerBox>.fromOpaque(data).takeUnretainedValue().handler()
            }
            g_signal_connect_data(
                UnsafeMutableRawPointer(storage.opaquePointer),
                "edge-reached",
                unsafeBitCast(callback, to: GCallback.self),
                Unmanaged.passUnretained(box).toOpaque(),
                nil,
                GConnectFlags(rawValue: 0)
            )
        }
    }

    /// Scrolls a scrolled window back to the top whenever `signal` fires.
    ///
    /// `Signal.update` is a mutating read: through a binding it writes the
    /// state back, which would re-render — and re-enter here — on every
    /// pass. Blocking updates around it (as the toolkit's own toast helper
    /// does) keeps the write from scheduling a render.
    func scrollToTop(on signal: Binding<Signal>) -> AnyView {
        inspect { storage, data, _ in
            data.stateManager.withBlockedUpdates {
                guard signal.wrappedValue.update,
                      let adjustment = gtk_scrolled_window_get_vadjustment(storage.opaquePointer) else { return }
                gtk_adjustment_set_value(adjustment, gtk_adjustment_get_lower(adjustment))
            }
        }
    }
}

// MARK: - Image fitting (gdk-pixbuf)

/// Fits picked images into Bluesky's ~1 MB blob budget with gdk-pixbuf:
/// downscale to a sane edge, re-encode as JPEG, and lower the quality
/// until it fits. The Apple app does the same with ImageIO.
struct PixbufMediaProcessor: PostMediaProcessing {

    struct Unsupported: Error {}
    struct DecodeFailed: Error {}

    static let maxBytes = 950_000
    static let maxEdge: Int32 = 2000

    func prepareVideo(at url: URL) async throws -> PreparedUploadVideo { throw Unsupported() }
    func renderVoiceMemo(at url: URL) async throws -> PreparedUploadVideo { throw Unsupported() }

    func prepareImage(_ data: Data) async throws -> PreparedUploadImage {
        guard let loader = gdk_pixbuf_loader_new() else { throw DecodeFailed() }
        defer { g_object_unref(loader) }
        let written = data.withUnsafeBytes { buffer -> gboolean in
            gdk_pixbuf_loader_write(loader, buffer.bindMemory(to: UInt8.self).baseAddress, gsize(buffer.count), nil)
        }
        gdk_pixbuf_loader_close(loader, nil)
        guard written != 0, var pixbuf: OpaquePointer = gdk_pixbuf_loader_get_pixbuf(loader) else { throw DecodeFailed() }
        // The loader owns this reference; take one of our own so the
        // scaled replacements below can be released uniformly.
        g_object_ref(UnsafeMutableRawPointer(pixbuf))
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }

        // Honour EXIF orientation before measuring.
        if let oriented = gdk_pixbuf_apply_embedded_orientation(pixbuf) {
            g_object_unref(UnsafeMutableRawPointer(pixbuf))
            pixbuf = oriented
        }

        var width = gdk_pixbuf_get_width(pixbuf)
        var height = gdk_pixbuf_get_height(pixbuf)
        let longest = max(width, height)
        if longest > Self.maxEdge {
            let scale = Double(Self.maxEdge) / Double(longest)
            let newWidth = max(1, Int32(Double(width) * scale))
            let newHeight = max(1, Int32(Double(height) * scale))
            if let scaled = gdk_pixbuf_scale_simple(pixbuf, newWidth, newHeight, GDK_INTERP_BILINEAR) {
                g_object_unref(UnsafeMutableRawPointer(pixbuf))
                pixbuf = scaled
                width = newWidth
                height = newHeight
            }
        }

        for quality in [88, 80, 70, 60, 50, 40] {
            if let encoded = Self.encodeJPEG(pixbuf, quality: quality) {
                if encoded.count <= Self.maxBytes {
                    return PreparedUploadImage(data: encoded, aspectRatio: (Int(width), Int(height)))
                }
            }
            // Still too large at the lowest quality: halve the edge and retry.
            if quality == 40 {
                let newWidth = max(1, width / 2)
                let newHeight = max(1, height / 2)
                if let scaled = gdk_pixbuf_scale_simple(pixbuf, newWidth, newHeight, GDK_INTERP_BILINEAR) {
                    g_object_unref(UnsafeMutableRawPointer(pixbuf))
                    pixbuf = scaled
                    width = newWidth
                    height = newHeight
                    if let encoded = Self.encodeJPEG(pixbuf, quality: 60) {
                        return PreparedUploadImage(data: encoded, aspectRatio: (Int(width), Int(height)))
                    }
                }
            }
        }
        throw DecodeFailed()
    }

    private static func encodeJPEG(_ pixbuf: OpaquePointer, quality: Int) -> Data? {
        var buffer: UnsafeMutablePointer<CChar>? = nil
        var size: gsize = 0
        let qualityString = strdup(String(quality))
        let keyString = strdup("quality")
        defer { free(qualityString); free(keyString) }
        var keys: [UnsafeMutablePointer<CChar>?] = [keyString, nil]
        var values: [UnsafeMutablePointer<CChar>?] = [qualityString, nil]
        let ok = keys.withUnsafeMutableBufferPointer { keysPointer in
            values.withUnsafeMutableBufferPointer { valuesPointer in
                gdk_pixbuf_save_to_bufferv(
                    pixbuf, &buffer, &size, "jpeg",
                    keysPointer.baseAddress, valuesPointer.baseAddress, nil
                )
            }
        }
        guard ok != 0, let buffer else { return nil }
        defer { g_free(buffer) }
        return Data(bytes: buffer, count: Int(size))
    }
}
