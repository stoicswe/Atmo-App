import Foundation

/// Bluesky's video-upload limits, enforced client-side so failures surface
/// as clear messages before (or instead of) an opaque server rejection.
/// The video service accepts MP4 (H.264) only, up to 100 MB and 3 minutes;
/// the platform layer is responsible for transcoding into that format —
/// these checks cover what transcoding can't fix.
public enum VideoConstraints {

    /// Maximum clip length the Bluesky video service accepts.
    public static let maxDuration: TimeInterval = 180

    /// Maximum upload size. ATProtoKit rejects uploads at or above this
    /// byte count, mirroring the service limit.
    public static let maxByteCount = 100_000_000

    public enum Violation: Error, Equatable, Sendable {
        case tooLong(seconds: TimeInterval)
        case tooLarge(byteCount: Int)

        /// Ready-to-display explanation for the composer UI.
        public var userMessage: String {
            switch self {
            case .tooLong:
                return "Videos can be up to 3 minutes long on Bluesky. Trim the clip and try again."
            case .tooLarge:
                return "That video is over Bluesky's 100 MB limit, even after compression. Try a shorter clip."
            }
        }
    }

    /// Checks a candidate upload. Duration is checked first (compression
    /// can't fix length); pass nil when the duration isn't known yet.
    public static func validate(byteCount: Int, duration: TimeInterval?) -> Violation? {
        if let duration, duration > maxDuration {
            return .tooLong(seconds: duration)
        }
        if byteCount >= maxByteCount {
            return .tooLarge(byteCount: byteCount)
        }
        return nil
    }
}
