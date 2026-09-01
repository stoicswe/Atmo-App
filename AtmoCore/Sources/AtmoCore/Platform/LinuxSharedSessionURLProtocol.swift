#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking

/// Linux crash shield for ATProtoKit's session lifecycle.
///
/// swift-corelibs-foundation's `URLSession` must be invalidated before it
/// is released; deallocating one whose libcurl socket teardown is still
/// in flight leaves a dangling `_MultiHandle` and aborts the process
/// (`_SocketSources.tearDown` → `_MultiHandle.endOperation`, preceded by
/// the "deallocated with non-zero retain count" warning). ATProtoKit's
/// `authenticate`/`refreshSession`/`registerSession`/`removeSession`
/// each build a throwaway `ATProtoKit` — and with it a throwaway
/// `URLSession` — for a single request, which trips exactly that: on
/// Linux, signing in crashed the app the moment the auth round-trip
/// finished. Darwin's Foundation has no such constraint, so upstream
/// never sees it.
///
/// Instead of forking ATProtoKit, this `URLProtocol` is installed into
/// the `URLSessionConfiguration` handed to `ATProtocolConfiguration`
/// (see `ATProtoService.makeConfiguration()`). Every kit ATProtoKit
/// creates — ephemeral or retained — inherits that configuration, so all
/// their requests are carried by the single immortal session below. The
/// throwaway sessions never open a curl socket of their own, and their
/// deallocation is harmless.
final class LinuxSharedSessionURLProtocol: URLProtocol {

    /// URLProtocol marks Sendable unavailable, so the completion handler
    /// can't capture `self` directly. Safe regardless: the handler only
    /// reads `client` (set once by the framework before `startLoading`)
    /// and calls its thread-safe callbacks.
    private final class WeakBox: @unchecked Sendable {
        weak var value: LinuxSharedSessionURLProtocol?
        init(_ value: LinuxSharedSessionURLProtocol) { self.value = value }
    }

    /// The one session that actually performs requests. Never released,
    /// never invalidated — which is precisely the point.
    /// Plain configuration: no `protocolClasses`, or it would recurse.
    private static let sharedSession = URLSession(configuration: .default)

    /// `startLoading` arrives on the outer task's dispatch lane, where
    /// `URLSession.dataTask(with:)`'s internal `queue.sync` trips
    /// libdispatch's deadlock detector. All shared-session work (and all
    /// `innerTask` access) hops to this private queue instead.
    private static let workerQueue = DispatchQueue(label: "com.atmo.shared-session-url-protocol")

    /// Only touched on `workerQueue`.
    private var innerTask: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool {
        let scheme = request.url?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var request = self.request
        // The loader may hand the body over as a stream; the inner task
        // needs it back as data.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Self.drain(stream)
        }
        let box = WeakBox(self)
        let preparedRequest = request
        Self.workerQueue.async {
            guard let outer = box.value else { return }
            let task = Self.sharedSession.dataTask(with: preparedRequest) { data, response, error in
                guard let self = box.value, let client = self.client else { return }
                if let response {
                    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                }
                if let data {
                    client.urlProtocol(self, didLoad: data)
                }
                if let error {
                    client.urlProtocol(self, didFailWithError: error)
                } else {
                    client.urlProtocolDidFinishLoading(self)
                }
            }
            outer.innerTask = task
            task.resume()
        }
    }

    override func stopLoading() {
        let box = WeakBox(self)
        Self.workerQueue.async {
            box.value?.innerTask?.cancel()
            box.value?.innerTask = nil
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
#endif
