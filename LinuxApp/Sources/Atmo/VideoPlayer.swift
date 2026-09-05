import Adwaita
import CAdw
import Foundation

// MARK: - GStreamer (dlopen'd)

/// Minimal GStreamer binding for inline video.
///
/// GTK 4.22 removed its built-in media backend, so `GtkVideo` can no
/// longer play anything — the supported path is GStreamer's
/// `gtk4paintablesink` (package `gstreamer1.0-gtk4`, staged in the snap)
/// rendering into a `GtkPicture`. The build machine has no GStreamer dev
/// headers, so the handful of libgstreamer entry points we need are
/// resolved at runtime with `dlopen`; every property/paintable
/// interaction goes through the GObject API that CAdw already links.
enum GStreamer {

    // GstState / GstFormat / GstSeekFlags values from gstreamer headers.
    static let stateNull: Int32 = 1
    static let statePaused: Int32 = 3
    static let statePlaying: Int32 = 4
    static let formatTime: Int32 = 3
    /// FLUSH | KEY_UNIT — snappy scrubbing that lands on keyframes.
    static let seekFlags: Int32 = 1 | 4

    private typealias InitFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void
    private typealias ParseLaunchFn = @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> UnsafeMutableRawPointer?
    private typealias SetStateFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias UnrefFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias FactoryFindFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias QueryFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Int64>?
    ) -> Int32
    private typealias SeekSimpleFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Int64
    ) -> Int32

    private static let library: UnsafeMutableRawPointer? = {
        guard let handle = dlopen("libgstreamer-1.0.so.0", RTLD_NOW | RTLD_GLOBAL) else { return nil }
        guard let initSym = dlsym(handle, "gst_init") else { return nil }
        unsafeBitCast(initSym, to: InitFn.self)(nil, nil)
        return handle
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let sym = dlsym(library, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// True when libgstreamer loads and the GTK4 sink element exists.
    static let available: Bool = {
        guard let find = symbol("gst_element_factory_find", as: FactoryFindFn.self),
              let factory = find("gtk4paintablesink") else { return false }
        symbol("gst_object_unref", as: UnrefFn.self)?(factory)
        return true
    }()

    /// Builds `playbin3` for the URI with a gtk4paintablesink and returns
    /// (pipeline, paintable) — the paintable goes into a `GtkPicture`.
    static func makePipeline(uri: String) -> (pipeline: UnsafeMutableRawPointer, paintable: OpaquePointer)? {
        guard available,
              let parse = symbol("gst_parse_launch", as: ParseLaunchFn.self),
              let pipeline = parse("playbin3 uri=\(uri) video-sink=gtk4paintablesink", nil)
        else { return nil }

        let playbin = pipeline.assumingMemoryBound(to: GObject.self)
        var sinkValue = GValue()
        g_value_init(&sinkValue, g_type_from_name("GstElement"))
        g_object_get_property(playbin, "video-sink", &sinkValue)
        guard let sinkRaw = g_value_get_object(&sinkValue) else {
            g_value_unset(&sinkValue)
            unref(pipeline)
            return nil
        }
        var paintableValue = GValue()
        g_value_init(&paintableValue, g_type_from_name("GdkPaintable"))
        g_object_get_property(
            UnsafeMutableRawPointer(sinkRaw).assumingMemoryBound(to: GObject.self),
            "paintable",
            &paintableValue
        )
        let paintable = g_value_get_object(&paintableValue).map { OpaquePointer($0) }
        g_value_unset(&paintableValue)
        g_value_unset(&sinkValue)
        guard let paintable else {
            unref(pipeline)
            return nil
        }
        return (pipeline, paintable)
    }

    static func setState(_ pipeline: UnsafeMutableRawPointer, _ state: Int32) {
        _ = symbol("gst_element_set_state", as: SetStateFn.self)?(pipeline, state)
    }

    static func unref(_ pipeline: UnsafeMutableRawPointer) {
        symbol("gst_object_unref", as: UnrefFn.self)?(pipeline)
    }

    /// Current position in nanoseconds, when known.
    static func position(_ pipeline: UnsafeMutableRawPointer) -> Int64? {
        var value: Int64 = -1
        guard symbol("gst_element_query_position", as: QueryFn.self)?(pipeline, formatTime, &value) != 0,
              value >= 0 else { return nil }
        return value
    }

    /// Stream duration in nanoseconds, when known.
    static func duration(_ pipeline: UnsafeMutableRawPointer) -> Int64? {
        var value: Int64 = -1
        guard symbol("gst_element_query_duration", as: QueryFn.self)?(pipeline, formatTime, &value) != 0,
              value > 0 else { return nil }
        return value
    }

    static func seek(_ pipeline: UnsafeMutableRawPointer, to nanoseconds: Int64) {
        _ = symbol("gst_element_seek_simple", as: SeekSimpleFn.self)?(
            pipeline, formatTime, seekFlags, max(0, nanoseconds)
        )
    }
}

// MARK: - Player widget

/// Inline HLS playback: a `GtkPicture` showing gtk4paintablesink's
/// paintable plus a transport row (play/pause, seek slider, position /
/// duration), driven by a per-widget playbin3 pipeline. The pipeline is
/// torn down with the widget — the feed's Stop pill removes the player,
/// which is also how playback fully stops.
struct VideoPlayer: AdwaitaWidget {

    /// Remote stream URI (the post's HLS playlist).
    var uri: String

    /// Inline playback is possible on this system.
    static var available: Bool { GStreamer.available }

    private static let scaleMax = 1000.0

    func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage where Data: ViewRenderData {
        let box = gtk_box_new(GtkOrientation(rawValue: 1)!, 4)
        let picture = gtk_picture_new()
        gtk_picture_set_can_shrink(picture?.opaque(), 1)
        gtk_picture_set_content_fit(picture?.opaque(), GtkContentFit(rawValue: 3)!) // SCALE_DOWN
        gtk_widget_set_hexpand(picture, 1)
        gtk_widget_set_vexpand(picture, 1)
        gtk_box_append(box?.cast(), picture)

        let controls = gtk_box_new(GtkOrientation(rawValue: 0)!, 6)
        gtk_widget_set_margin_start(controls, 4)
        gtk_widget_set_margin_end(controls, 4)
        let playButton = gtk_button_new_from_icon_name("media-playback-pause-symbolic")
        gtk_widget_add_css_class(playButton, "flat")
        gtk_widget_add_css_class(playButton, "circular")
        let scale = gtk_scale_new_with_range(GtkOrientation(rawValue: 0)!, 0, Self.scaleMax, 1)
        gtk_widget_set_hexpand(scale, 1)
        gtk_widget_set_sensitive(scale, 0) // until the duration is known
        let timeLabel = gtk_label_new("0:00")
        gtk_widget_add_css_class(timeLabel, "numeric")
        gtk_widget_add_css_class(timeLabel, "dim-label")
        gtk_box_append(controls?.cast(), playButton)
        gtk_box_append(controls?.cast(), scale)
        gtk_box_append(controls?.cast(), timeLabel)
        gtk_box_append(box?.cast(), controls)

        let storage = ViewStorage(box?.opaque())
        storage.fields["picture"] = picture.map { OpaquePointer($0) }
        storage.fields["scale"] = scale.map { OpaquePointer($0) }
        storage.fields["timeLabel"] = timeLabel.map { OpaquePointer($0) }
        storage.fields["playButton"] = playButton.map { OpaquePointer($0) }

        // Sub-widget signal plumbing keeps closures alive via storages.
        let buttonStorage = ViewStorage(playButton?.opaque())
        buttonStorage.connectSignal(name: "clicked", type: .noArgs) { _ in
            Self.togglePlayback(storage)
        }
        storage.fields["buttonStorage"] = buttonStorage

        let scaleStorage = ViewStorage(scale?.opaque())
        scaleStorage.connectSignal(name: "value-changed", type: .noArgs) { _ in
            // Fires for user drags AND the timer's programmatic updates —
            // the guard flag separates the two.
            guard storage.fields["scrubGuard"] == nil,
                  let pipeline = storage.fields["pipeline"] as? UnsafeMutableRawPointer,
                  let duration = storage.fields["durationNS"] as? Int64,
                  let scalePtr = storage.fields["scale"] as? OpaquePointer
            else { return }
            let fraction = gtk_range_get_value(UnsafeMutablePointer<GtkRange>(scalePtr)) / Self.scaleMax
            GStreamer.seek(pipeline, to: Int64(fraction * Double(duration)))
        }
        storage.fields["scaleStorage"] = scaleStorage

        // Stop the stream (and its audio) the moment the widget goes away.
        storage.connectSignal(name: "destroy", type: .noArgs) { _ in
            Self.teardown(storage)
        }

        update(storage, data: data, updateProperties: true, type: type)
        return storage
    }

    func update<Data>(
        _ storage: ViewStorage,
        data: WidgetData,
        updateProperties: Bool,
        type: Data.Type
    ) where Data: ViewRenderData {
        guard updateProperties, storage.fields["uri"] as? String != uri else { return }
        Self.teardown(storage)
        storage.fields["uri"] = uri
        guard let (pipeline, paintable) = GStreamer.makePipeline(uri: uri) else {
            FileHandle.standardError.write(Foundation.Data("[video] pipeline setup failed for \(uri)\n".utf8))
            return
        }
        storage.fields["pipeline"] = pipeline
        storage.fields["isPlaying"] = true
        if let picture = storage.fields["picture"] as? OpaquePointer {
            gtk_picture_set_paintable(picture, paintable)
        }
        GStreamer.setState(pipeline, GStreamer.statePlaying)

        // Transport clock: twice a second, sync the slider and label —
        // ends itself once the pipeline is gone.
        Idle(delay: 500) {
            guard storage.fields["pipeline"] as? UnsafeMutableRawPointer != nil else { return false }
            Self.syncTransport(storage)
            return true
        }
    }

    // MARK: - Controls

    private static func togglePlayback(_ storage: ViewStorage) {
        guard let pipeline = storage.fields["pipeline"] as? UnsafeMutableRawPointer else { return }
        let playing = storage.fields["isPlaying"] as? Bool ?? true
        storage.fields["isPlaying"] = !playing
        GStreamer.setState(pipeline, playing ? GStreamer.statePaused : GStreamer.statePlaying)
        if let button = storage.fields["playButton"] as? OpaquePointer {
            gtk_button_set_icon_name(
                UnsafeMutablePointer<GtkButton>(button),
                playing ? "media-playback-start-symbolic" : "media-playback-pause-symbolic"
            )
        }
    }

    private static func syncTransport(_ storage: ViewStorage) {
        guard let pipeline = storage.fields["pipeline"] as? UnsafeMutableRawPointer else { return }
        let duration = GStreamer.duration(pipeline)
        let position = GStreamer.position(pipeline) ?? 0
        storage.fields["durationNS"] = duration
        if let label = storage.fields["timeLabel"] as? OpaquePointer {
            let text = duration.map { "\(clock(position)) / \(clock($0))" } ?? clock(position)
            gtk_label_set_label(label, text)
        }
        guard let scale = storage.fields["scale"] as? OpaquePointer else { return }
        if let duration {
            gtk_widget_set_sensitive(UnsafeMutablePointer(scale), 1)
            storage.fields["scrubGuard"] = true
            gtk_range_set_value(UnsafeMutablePointer<GtkRange>(scale), Double(position) / Double(duration) * scaleMax)
            storage.fields["scrubGuard"] = nil
        } else {
            gtk_widget_set_sensitive(UnsafeMutablePointer(scale), 0)
        }
    }

    private static func teardown(_ storage: ViewStorage) {
        guard let pipeline = storage.fields["pipeline"] as? UnsafeMutableRawPointer else { return }
        storage.fields["pipeline"] = nil
        storage.fields["durationNS"] = nil
        GStreamer.setState(pipeline, GStreamer.stateNull)
        GStreamer.unref(pipeline)
    }

    private static func clock(_ nanoseconds: Int64) -> String {
        let seconds = Int(nanoseconds / 1_000_000_000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
