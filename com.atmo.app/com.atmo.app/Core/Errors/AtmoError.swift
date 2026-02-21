import Foundation

enum AtmoError: LocalizedError {
    case notAuthenticated
    case sessionExpired
    case networkUnavailable
    case postTooLong(characterCount: Int)
    case invalidHandle
    case unknown(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You are not signed in. Please log in to continue."
        case .sessionExpired:
            return "Your session has expired. Please sign in again."
        case .networkUnavailable:
            return "No network connection. Please check your internet settings."
        case .postTooLong(let count):
            return "Post is too long (\(count)/300 characters)."
        case .invalidHandle:
            return "Invalid handle. Use the format username.bsky.social."
        case .unknown(let error):
            return error.localizedDescription
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAuthenticated, .sessionExpired:
            return "Tap Sign In to authenticate."
        case .networkUnavailable:
            return "Connect to Wi-Fi or cellular and try again."
        default:
            return nil
        }
    }
}
