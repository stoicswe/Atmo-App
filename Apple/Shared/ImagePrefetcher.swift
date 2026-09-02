import Foundation
import ATProtoKit
import AtmoCore

// MARK: - Image Prefetcher
/// Warms the URL cache for images about to scroll into view — post
/// thumbnails and avatars for the newest rows — at low priority, so by
/// the time a cell appears its bytes are usually already on disk.
/// Nothing is decoded here; AsyncCachedImage does that on demand.
enum ImagePrefetcher {
    private static let lock = NSLock()
    private static var inFlight: Set<URL> = []
    private static var seen: Set<URL> = []
    private static let maxInFlight = 6

    /// Thumbnails and small avatars for `posts` (bounded).
    static func prefetch(posts: [PostItem], limit: Int = 30) {
        var urls: [URL] = []
        for post in posts.prefix(limit) {
            if let avatar = post.authorAvatarURL {
                urls.append(BlueskyCDN.avatarThumbnail(avatar))
            }
            switch post.media {
            case .images(let images):
                if let first = images.first { urls.append(first.thumbnailImageURL) }
            case .video(let video):
                if let thumb = video.thumbnailImageURL.flatMap(URL.init(string:)) { urls.append(thumb) }
            case .gif(_, let thumbnailURL, _):
                if let thumbnailURL { urls.append(thumbnailURL) }
            case nil:
                break
            }
        }
        prefetch(urls)
    }

    static func prefetch(_ urls: [URL]) {
        for url in urls {
            lock.lock()
            let shouldStart = !seen.contains(url) && inFlight.count < maxInFlight
            if shouldStart {
                seen.insert(url)
                inFlight.insert(url)
                if seen.count > 2000 { seen.removeAll() }
            }
            lock.unlock()
            guard shouldStart else { continue }

            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
            request.networkServiceType = .background
            let task = URLSession.cachedSession.dataTask(with: request) { _, _, _ in
                lock.lock()
                inFlight.remove(url)
                lock.unlock()
            }
            task.priority = URLSessionTask.lowPriority
            task.resume()
        }
    }
}
