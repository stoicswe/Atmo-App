import Foundation
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
}
