import SwiftUI
import AVFoundation
import AtmoCore

// MARK: - Attached Video Preview
/// Thumbnail tile for a video or voice-memo reference in the composer,
/// matching the photo tiles: a real frame from the referenced clip (a
/// waveform glyph tile for audio takes, which have no frames until they
/// render at publish time) at the photo row's 96 pt height, with the same
/// ✕ remove control, plus a duration badge.
struct AttachedVideoPreview: View {
    let attachment: PostSlot.VideoAttachment
    let onRemove: () -> Void

    @State private var thumbnail: PlatformImage? = nil
    @State private var failed = false

    /// Photo-row height, width following the clip's aspect ratio within
    /// sane bounds (portrait clips stay at least square-ish, panoramas cap).
    private var tileWidth: CGFloat {
        guard let ratio = attachment.aspectRatio, ratio.width > 0, ratio.height > 0 else { return 128 }
        return min(170, max(72, 96 * CGFloat(ratio.width) / CGFloat(ratio.height)))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.isVoiceMemo {
                    // Audio reference — the waveform video doesn't exist
                    // yet; a glyph tile stands in for it.
                    ZStack {
                        Color.black.opacity(0.75)
                        Image(systemName: "waveform")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(AtmoColors.accent)
                    }
                } else if let thumbnail {
                    Image(platformImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        if failed {
                            Image(systemName: "video.fill")
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
            .accessibilityLabel(attachment.isVoiceMemo ? "Remove voice memo" : "Remove video")
        }
        .task(id: attachment.id) { await loadThumbnail() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.isVoiceMemo ? "Voice memo attached" : "Video attached")
    }

    /// Media-type + duration capsule, mirroring the photo tiles' ALT badge.
    private var badge: some View {
        HStack(spacing: 3) {
            Image(systemName: attachment.isVoiceMemo ? "waveform" : "play.fill")
                .font(.caption2.weight(.bold))
            if let duration = attachment.duration {
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

    /// Decodes one poster frame from the referenced video file (memos have
    /// no frames — their branch above never gets here).
    private func loadThumbnail() async {
        guard !attachment.isVoiceMemo else { return }
        if let cached = VideoPreviewCache.values[attachment.id] {
            thumbnail = cached
            return
        }
        let url = attachment.fileURL
        let cgImage: CGImage? = await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            // A hair in, so the first decoded frame isn't a black leader.
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            let time = CMTime(seconds: min(0.1, max(0, seconds / 2)), preferredTimescale: 600)
            return try? await generator.image(at: time).image
        }.value

        guard let cgImage else {
            failed = true
            return
        }
#if os(iOS)
        let image = UIImage(cgImage: cgImage)
#else
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
#endif
        VideoPreviewCache.values[attachment.id] = image
        thumbnail = image
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
    static var values: [UUID: PlatformImage] = [:]
}
