import Foundation
import AVFoundation
import AtmoCore

// MARK: - Video Preparer
/// Turns whatever the Photos picker hands over (typically a QuickTime .mov,
/// often HEVC) into an upload Bluesky's video service actually accepts:
/// an H.264 MP4 under the 100 MB cap. Raw picker bytes uploaded with an
/// .mp4 filename were the reason video posts failed — the container and
/// codec never matched the name.
/// `nonisolated`: transcoding runs off the main actor (the app target
/// defaults to MainActor isolation) — publish-time processing must never
/// stall the UI.
nonisolated enum VideoPreparer {

    struct Prepared {
        let data: Data
        let fileName: String
        let aspectRatio: (width: Int, height: Int)?
    }

    enum PrepareError: Error {
        case unreadable
        case exportFailed
    }

    /// Validates the clip length, then transcodes stepping down the
    /// resolution ladder until the result fits the size limit.
    static func prepareForUpload(at inputURL: URL) async throws -> Prepared {
        let directory = FileManager.default.temporaryDirectory
        let asset = AVURLAsset(url: inputURL)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else {
            throw PrepareError.unreadable
        }
        // Length first — no amount of compression fixes an overlong clip.
        if let violation = VideoConstraints.validate(byteCount: 0, duration: duration) {
            throw violation
        }

        // H.264 presets, largest first. Most clips fit at 1080p; long ones
        // step down until they clear the 100 MB cap.
        let presets = [
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPreset960x540,
        ]

        var lastByteCount = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int) ?? 0
        var exportedAny = false
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.shouldOptimizeForNetworkUse = true

            let outputURL = directory.appendingPathComponent("atmo-video-out-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: outputURL) }
            do {
                try await session.export(to: outputURL, as: .mp4)
            } catch {
                continue
            }
            guard let data = try? Data(contentsOf: outputURL) else { continue }
            exportedAny = true
            lastByteCount = data.count

            if VideoConstraints.validate(byteCount: data.count, duration: nil) == nil {
                let ratio = await dimensions(ofVideoAt: outputURL)
                return Prepared(
                    data: data,
                    fileName: "video-\(UUID().uuidString).mp4",
                    aspectRatio: ratio
                )
            }
        }

        // Every rung either failed or still exceeded the cap.
        if exportedAny {
            throw VideoConstraints.Violation.tooLarge(byteCount: lastByteCount)
        }
        throw PrepareError.exportFailed
    }

    /// Orientation-corrected pixel dimensions of a video file. Internal:
    /// the composer also uses this at pick time for the preview tile's
    /// aspect hint (no transcode happens until publish).
    static func dimensions(ofVideoAt url: URL) async -> (width: Int, height: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let width = abs(Int(rect.width.rounded()))
        let height = abs(Int(rect.height.rounded()))
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
