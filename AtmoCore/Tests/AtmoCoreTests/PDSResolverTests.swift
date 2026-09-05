import Foundation
import Testing
import ATProtoKit
@testable import AtmoCore

/// Covers the sign-in plumbing that doesn't need a server: which
/// identifiers get their hosting service resolved, how the resolveHandle
/// payload is read, App Password detection, and the 2FA error check.
struct PDSResolverTests {

    @Test func handlesAreResolvableEmailsAndBareNamesAreNot() {
        #expect(PDSResolver.isResolvable("alice.bsky.social"))
        #expect(PDSResolver.isResolvable("alice.example.com"))
        #expect(!PDSResolver.isResolvable("alice"))
        #expect(!PDSResolver.isResolvable("alice@example.com"))
        #expect(!PDSResolver.isResolvable("alice .bsky.social"))
        #expect(!PDSResolver.isResolvable(".bsky.social"))
        #expect(!PDSResolver.isResolvable("alice."))
        #expect(!PDSResolver.isResolvable(""))
    }

    @Test func resolveHandleRequestTargetsPublicAPI() throws {
        let url = try #require(PDSResolver.resolveHandleURL("Alice.Example.com"))
        #expect(url.host == "public.api.bsky.app")
        #expect(url.path == "/xrpc/com.atproto.identity.resolveHandle")
        #expect(url.query == "handle=alice.example.com")
    }

    @Test func parsesDIDFromPayload() {
        #expect(PDSResolver.parseDID(from: Data(#"{"did":"did:plc:abc123"}"#.utf8)) == "did:plc:abc123")
        #expect(PDSResolver.parseDID(from: Data(#"{"did":"nope"}"#.utf8)) == nil)
        #expect(PDSResolver.parseDID(from: Data(#"{"error":"InvalidRequest"}"#.utf8)) == nil)
        #expect(PDSResolver.parseDID(from: Data()) == nil)
    }

    @Test func blueskyFleetHostsSignInAtTheEntryway() {
        #expect(PDSResolver.signInURL(forPDS: URL(string: "https://puffball.us-east.host.bsky.network")!) == PDSResolver.defaultPDS)
        #expect(PDSResolver.signInURL(forPDS: URL(string: "https://inkcap.us-east.host.bsky.network")!) == PDSResolver.defaultPDS)
        let thirdParty = URL(string: "https://pds.example.com")!
        #expect(PDSResolver.signInURL(forPDS: thirdParty) == thirdParty)
        // A lookalike domain is not the fleet.
        let lookalike = URL(string: "https://notbsky.network.example.com")!
        #expect(PDSResolver.signInURL(forPDS: lookalike) == lookalike)
    }

    @Test func displayHost() {
        #expect(PDSResolver.displayHost(URL(string: "https://pds.example.com")!) == "pds.example.com")
        #expect(PDSResolver.displayHost(PDSResolver.defaultPDS) == "bsky.social")
    }

    @Test func appPasswordShape() {
        #expect(PDSResolver.isAppPassword("abcd-efgh-ijkl-mnop"))
        #expect(PDSResolver.isAppPassword("a1b2-c3d4-e5f6-g7h8"))
        #expect(!PDSResolver.isAppPassword("hunter2"))
        #expect(!PDSResolver.isAppPassword("ABCD-EFGH-IJKL-MNOP"))
        #expect(!PDSResolver.isAppPassword("abcd-efgh-ijkl"))
    }

    @Test func twoFactorRequiredDetection() throws {
        #expect(ATProtoService.isTwoFactorRequired(code: "AuthFactorTokenRequired"))
        #expect(!ATProtoService.isTwoFactorRequired(code: "AuthenticationRequired"))

        let payload = Data(#"{"error":"AuthFactorTokenRequired","message":"A sign in code has been sent to your email address"}"#.utf8)
        let response = try JSONDecoder().decode(APIClientService.ATHTTPResponseError.self, from: payload)
        #expect(ATProtoService.isTwoFactorRequired(ATAPIError.badRequest(error: response)))
        #expect(ATProtoService.isTwoFactorRequired(ATAPIError.unauthorized(error: response, wwwAuthenticate: nil)))

        let other = try JSONDecoder().decode(
            APIClientService.ATHTTPResponseError.self,
            from: Data(#"{"error":"AuthenticationRequired","message":"Invalid identifier or password"}"#.utf8)
        )
        #expect(!ATProtoService.isTwoFactorRequired(ATAPIError.badRequest(error: other)))
        #expect(!ATProtoService.isTwoFactorRequired(URLError(.notConnectedToInternet)))
    }

    @Test @MainActor func viewModelPassesEmailsThroughAndDetectsAppPasswords() {
        let vm = AuthViewModel()
        vm.handle = "alice@example.com"
        #expect(vm.normalizedHandle == "alice@example.com")
        vm.appPassword = "abcd-efgh-ijkl-mnop"
        #expect(vm.isAppPassword)
        vm.appPassword = "my real password"
        #expect(!vm.isAppPassword)
        #expect(vm.pdsDisplayHost == "bsky.social")
    }
}
