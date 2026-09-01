import Foundation
import ImageIO
import UniformTypeIdentifiers
import AtmoCore

// MARK: - Apple Media Processor
/// The AVFoundation-backed implementation of AtmoCore's publish-time
/// media seam: PostPublisher hands over the composer's references (a
/// picked video file, a voice-memo take) and gets upload-ready bytes.
/// Installed in AtmoApp.init(), after `Atmo.platform = .apple`.
///
/// `nonisolated`: called from the publisher's engine; the underlying
/// preparers already run off the main actor.
nonisolated struct AppleMediaProcessor: PostMediaProcessing {

    func prepareVideo(at url: URL) async throws -> PreparedUploadVideo {
        let prepared = try await VideoPreparer.prepareForUpload(at: url)
        return PreparedUploadVideo(
            data: prepared.data,
            fileName: prepared.fileName,
            aspectRatio: prepared.aspectRatio
        )
    }

    func renderVoiceMemo(at url: URL) async throws -> PreparedUploadVideo {
        let rendered = try await WaveformVideoRenderer.render(audioURL: url)
        return PreparedUploadVideo(
            data: rendered.data,
            fileName: rendered.fileName,
            aspectRatio: rendered.aspectRatio
        )
    }

    // MARK: - Images

    enum ImageError: Error {
        case unreadable
        case cannotFit
    }

    /// Bluesky's image blob cap is 1,000,000 bytes — raw picker/camera
    /// bytes (multi-MB HEIC) blow straight past it and fail the whole
    /// post. Small JPEGs pass through untouched; everything else is
    /// downsampled (orientation-corrected) and re-encoded as JPEG,
    /// stepping dimensions and quality down until it fits.
    func prepareImage(_ data: Data) async throws -> PreparedUploadImage {
        let byteBudget = 950_000

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageError.unreadable
        }

        // Fast path: an in-budget JPEG uploads as-is.
        if data.count <= byteBudget,
           let type = CGImageSourceGetType(source) as String?,
           type == UTType.jpeg.identifier {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int
            let height = properties?[kCGImagePropertyPixelHeight] as? Int
            let ratio = (width != nil && height != nil) ? (width!, height!) : nil
            return PreparedUploadImage(data: data, aspectRatio: ratio)
        }

        for maxDimension in [2048, 1600, 1280, 1024, 800] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // bake in orientation
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                continue
            }
            for quality in [0.85, 0.75, 0.6, 0.45] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output, UTType.jpeg.identifier as CFString, 1, nil
                ) else { continue }
                CGImageDestinationAddImage(destination, image, [
                    kCGImageDestinationLossyCompressionQuality: quality,
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { continue }
                if output.length <= byteBudget {
                    return PreparedUploadImage(
                        data: output as Data,
                        aspectRatio: (image.width, image.height)
                    )
                }
            }
        }
        throw ImageError.cannotFit
    }
}
