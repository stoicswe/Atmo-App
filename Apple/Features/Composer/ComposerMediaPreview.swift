import SwiftUI
import AVFoundation
import AtmoCore

// MARK: - Attached Video Preview
/// Thumbnail tile for a video or voice-memo attachment in the composer,
/// matching the photo tiles: a real frame from the clip (for memos, the
/// rendered waveform) at the photo row's 96 pt height, with the same ✕
/// remove control, plus a duration badge.
struct AttachedVideoPreview: View {
    let attachment: PostSlot.VideoAttachment
    let onRemove: () -> Void

    @State private var thumbnail: PlatformImage? = nil
    @State private var duration: TimeInterval? = nil
    @State private var failed = false

    /// Voice memos arrive from VoiceMemoSheet with a "voice-" filename —
    /// their badge wears the waveform glyph instead of the play triangle.
    private var isVoiceMemo: Bool { attachment.fileName.hasPrefix("voice-") }

    /// Photo-row height, width following the clip's aspect ratio within
    /// sane bounds (portrait clips stay at least square-ish, panoramas cap).
    private var tileWidth: CGFloat {
        guard let ratio = attachment.aspectRatio, ratio.width > 0, ratio.height > 0 else { return 128 }
        return min(170, max(72, 96 * CGFloat(ratio.width) / CGFloat(ratio.height)))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(platformImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        if failed {
                            Image(systemName: isVoiceMemo ? "waveform" : "video.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
            .frame(width: tileWidth, height: 96)
            .clipShape(RoundedRectangle(
                cornerRadius: AtmoTheme.CornerRadius.small,
                style: .continuous
            ))
            .overlay(alignment: .bottomLeading) { badge }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel(isVoiceMemo ? "Remove voice memo" : "Remove video")
        }
        .task(id: attachment.id) { await loadPreview() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isVoiceMemo ? "Voice memo attached" : "Video attached")
    }

    /// Media-type + duration capsule, mirroring the photo tiles' ALT badge.
    private var badge: some View {
        HStack(spacing: 3) {
            Image(systemName: isVoiceMemo ? "waveform" : "play.fill")
                .font(.caption2.weight(.bold))
            if let duration {
                Text(Self.timeString(duration))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.6)))
        .padding(4)
    }

    private func loadPreview() async {
        if let cached = VideoPreviewCache.values[attachment.id] {
            thumbnail = cached.image
            duration = cached.duration
            return
        }
        let data = attachment.data
        let id = attachment.id
        // The generator needs a file; decode off the main actor.
        let result: (image: CGImage, duration: TimeInterval)? = await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("atmo-attach-preview-\(id.uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try data.write(to: url)
                let asset = AVURLAsset(url: url)
                let seconds = try await asset.load(.duration).seconds
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 480)
                // A hair in, so the first decoded frame isn't a black leader.
                let time = CMTime(seconds: min(0.1, max(0, seconds / 2)), preferredTimescale: 600)
                let cgImage = try await generator.image(at: time).image
                return (cgImage, seconds)
            } catch {
                return nil
            }
        }.value

        guard let result else {
            failed = true
            return
        }
#if os(iOS)
        let image = UIImage(cgImage: result.image)
#else
        let image = NSImage(
            cgImage: result.image,
            size: NSSize(width: result.image.width, height: result.image.height)
        )
#endif
        VideoPreviewCache.values[attachment.id] = (image, result.duration)
        thumbnail = image
        duration = result.duration
    }

    private static func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Preview Cache
/// Session cache of generated attachment thumbnails, keyed by attachment
/// id — composer rows re-render constantly while typing, and the frame
/// only needs decoding once.
@MainActor
private enum VideoPreviewCache {
    static var values: [UUID: (image: PlatformImage, duration: TimeInterval)] = [:]
}
