import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ATProtoKit

// MARK: - PDS Resolver
/// Finds the hosting service (PDS) behind a handle, so sign-in goes to
/// the account's own server instead of assuming bsky.social. Two hops,
/// both public and unauthenticated: handle → DID through the AppView's
/// `resolveHandle`, then DID → PDS endpoint from the DID document
/// (plc.directory or did:web). Anything that isn't a handle — an email,
/// a bare word — skips resolution and uses the default host.
public enum PDSResolver {

    public enum ResolutionError: Error, Equatable {
        case notAHandle
        case handleNotFound
        case badEndpoint
    }

    public static let defaultPDS = URL(string: "https://bsky.social")!
    static let publicAPI = URL(string: "https://public.api.bsky.app")!

    /// Whether `identifier` looks like a handle worth resolving: at least
    /// one dot, no `@` inside (that's an email), no whitespace.
    public static func isResolvable(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("."),
              !trimmed.contains("@"), !trimmed.contains(" ")
        else { return false }
        guard let last = trimmed.split(separator: ".").last, last.count >= 2 else { return false }
        return !trimmed.hasPrefix(".") && !trimmed.hasSuffix(".")
    }

    /// Host shown to the person ("bsky.social", "pds.example.com").
    public static func displayHost(_ url: URL) -> String {
        url.host ?? url.absoluteString
    }

    /// Bluesky App Passwords are four dash-separated groups of four
    /// lowercase alphanumerics. They never trigger email 2FA.
    public static func isAppPassword(_ password: String) -> Bool {
        let pattern = #"^[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$"#
        return password.range(of: pattern, options: .regularExpression) != nil
    }

    /// Resolves the server to sign in through for `handle`. Throws when
    /// the handle is unknown or its DID document has no AT Protocol
    /// service.
    public static func resolve(handle: String, session: URLSession = .shared) async throws -> URL {
        guard isResolvable(handle) else { throw ResolutionError.notAHandle }
        let did = try await resolveDID(handle: handle, session: session)
        let endpoint = try await ATBuiltInIdentityResolver(urlSession: session).resolvePDSEndpoint(from: did)
        guard let url = URL(string: endpoint), url.host != nil else { throw ResolutionError.badEndpoint }
        return signInURL(forPDS: url)
    }

    /// Bluesky-hosted accounts live on a fleet PDS (`*.host.bsky.network`)
    /// whose credentials are held by the entryway, bsky.social — that's
    /// where their sessions are created. Any other PDS signs in directly.
    public static func signInURL(forPDS url: URL) -> URL {
        guard let host = url.host?.lowercased() else { return url }
        if host == "bsky.network" || host.hasSuffix(".bsky.network") {
            return defaultPDS
        }
        return url
    }

    static func resolveHandleURL(_ handle: String) -> URL? {
        var components = URLComponents(url: publicAPI.appendingPathComponent("xrpc/com.atproto.identity.resolveHandle"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "handle", value: handle.lowercased())]
        return components?.url
    }

    static func resolveDID(handle: String, session: URLSession) async throws -> String {
        guard let url = resolveHandleURL(handle) else { throw ResolutionError.notAHandle }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ResolutionError.handleNotFound
        }
        guard let did = parseDID(from: data) else { throw ResolutionError.handleNotFound }
        return did
    }

    /// Pulls the DID out of a `resolveHandle` payload. Pure; unit-tested.
    static func parseDID(from data: Data) -> String? {
        struct Output: Decodable { let did: String }
        guard let output = try? JSONDecoder().decode(Output.self, from: data),
              output.did.hasPrefix("did:")
        else { return nil }
        return output.did
    }
}

// MARK: - PDS Store
/// Remembers which PDS the stored session belongs to, so the cold-start
/// refresh talks to the right server. Not a secret; plain UserDefaults.
enum PDSStore {
    static let key = "atmo.session.pdsURL"

    static func save(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: key)
    }

    static func load() -> URL? {
        UserDefaults.standard.string(forKey: key).flatMap(URL.init(string:))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
