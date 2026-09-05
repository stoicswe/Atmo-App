#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking
import ATProtoKit

/// Linux fix for signed-in requests going out anonymous.
///
/// ATProtoKit flags the calls that need the session token by stamping a
/// `URLProtocol.setProperty` marker on the request and reading it back
/// in `APIClientService`. swift-corelibs-foundation implements neither
/// half — `URLProtocol.property(forKey:in:)` always returns nil — so on
/// Linux the marker never survives, the session's authenticator is told
/// "no authorization needed", and every feed, search, and profile call
/// answered `AuthMissing`. This authenticator decides from the request
/// itself instead: any `/xrpc/` call that isn't one of the handful of
/// anonymous endpoints and carries no `Authorization` header of its own
/// (refreshSession sets the refresh token itself) gets the access token.
///
/// Installed by `ATProtoService.buildStack()` through
/// `APIClientConfiguration.requestAuthenticator`; Darwin keeps the stock
/// behaviour.
struct LinuxRequestAuthenticator: ATRequestAuthenticator {

    let session: ATProtocolConfiguration

    /// Endpoints the PDS serves without a session (adding a token to
    /// `createSession` with a stale one could even be rejected).
    private static let anonymousEndpoints: Set<String> = [
        "com.atproto.server.createSession",
        "com.atproto.server.createAccount",
        "com.atproto.server.describeServer",
        "com.atproto.server.refreshSession",
        "com.atproto.server.deleteSession",
        "com.atproto.identity.resolveHandle",
        "com.atproto.server.requestPasswordReset",
        "com.atproto.server.resetPassword",
    ]

    func authenticatedRequest(
        for request: URLRequest,
        authorizationRequirement: ATRequestAuthorizationRequirement
    ) async throws -> URLRequest {
        if authorizationRequirement == .session {
            return try await session.authenticatedRequest(for: request, authorizationRequirement: .session)
        }
        guard Self.needsSession(request) else { return request }
        return try await session.authenticatedRequest(for: request, authorizationRequirement: .session)
    }

    static func needsSession(_ request: URLRequest) -> Bool {
        guard request.value(forHTTPHeaderField: "Authorization") == nil,
              let path = request.url?.path, path.hasPrefix("/xrpc/") else { return false }
        let nsid = String(path.dropFirst("/xrpc/".count))
        return !anonymousEndpoints.contains(nsid)
    }
}
#endif
