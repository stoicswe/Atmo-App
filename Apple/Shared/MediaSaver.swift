import Foundation
import Photos
import AtmoCore

// MARK: - Media Save State
/// Shared button state for save-to-Photos controls (image viewer, video
/// player): idle glyph → spinner → brief checkmark.
enum MediaSaveState: Equatable {
    case idle
    case saving
    case saved
}

// MARK: - Media Saver
/// Saves Bluesky media to the user's photo library (add-only access).
///
/// Images download directly from the CDN. Videos stream as HLS — which
/// Photos can't store — so the original MP4 blob is fetched from the
/// author's PDS instead: playlist URL → DID document → PDS endpoint →
/// `com.atproto.sync.getBlob` (see VideoBlobLocator for the pure chain).
nonisolated enum MediaSaver {

    enum SaveError: LocalizedError {
        case photosAccessDenied
        case downloadFailed
        case videoSourceUnavailable

        var errorDescription: String? {
            switch self {
            case .photosAccessDenied:
                return "Photos access is off. Allow “Add Photos Only” for @omic in Settings to save media."
            case .downloadFailed:
                return "The media couldn't be downloaded. Check your connection and try again."
            case .videoSourceUnavailable:
                return "The original video file isn't available from this post's server."
            }
        }
    }

    // MARK: Images

    static func saveImage(from url: URL) async throws {
        try await ensureAddAccess()
        let data = try await fetchData(from: url)
        try await saveImage(data: data)
    }

    /// Saves image bytes already in hand (an Enhanced copy).
    static func saveImage(data: Data) async throws {
        try await ensureAddAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    // MARK: Videos

    static func saveVideo(fromPlaylist playlistURL: URL) async throws {
        try await ensureAddAccess()

        guard let blobURL = await VideoBlobLocator.resolveBlobURL(playlistURL: playlistURL) else {
            throw SaveError.videoSourceUnavailable
        }

        // Blobs can be large (up to 100 MB) — stream to disk, and give the
        // file a real .mp4 name so Photos recognizes the container.
        let (downloaded, response) = try await URLSession.shared.download(from: blobURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: downloaded)
            throw SaveError.downloadFailed
        }
        let mp4 = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmo-save-\(UUID().uuidString).mp4")
        try FileManager.default.moveItem(at: downloaded, to: mp4)
        defer { try? FileManager.default.removeItem(at: mp4) }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: mp4, options: nil)
        }
    }

    // MARK: Shared plumbing

    private static func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty
        else { throw SaveError.downloadFailed }
        return data
    }

    private static func ensureAddAccess() async throws {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else {
                throw SaveError.photosAccessDenied
            }
        default:
            throw SaveError.photosAccessDenied
        }
    }
}
