import Foundation
import Testing
@testable import AtmoCore

/// Secrets store stub whose stored handle is fixed at construction, so a
/// test controls whether a "previous session" is on record without
/// touching UserDefaults or the Keychain.
private struct StubSecretsStore: SecretsStoring {
    let handle: String?

    func saveLastHandle(_ handle: String) {}
    func loadLastHandle() -> String? { handle }
    func stableSessionUUID() -> UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
    func clearAll() {}
}

/// The auth-phase lifecycle exists so UI layers can hold a splash during
/// the cold-start session restore instead of flashing the login form —
/// on macOS the login form's credential fields summon the system
/// password AutoFill panel, which then lingers over the signed-in window.
@MainActor
struct AuthPhaseTests {

    private func withPlatform<T>(
        lastHandle: String?,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let saved = Atmo.platform
        Atmo.platform = AtmoPlatform(
            secrets: StubSecretsStore(handle: lastHandle),
            makeCredentialStore: { FileCredentialStore() }
        )
        defer { Atmo.platform = saved }
        return try await body()
    }

    @Test func launchStartsInRestoringPhase() {
        let service = ATProtoService()
        #expect(service.authPhase == .restoring)
        #expect(!service.isAuthenticated)
    }

    @Test func restoreWithNoStoredSessionLandsOnLogin() async {
        await withPlatform(lastHandle: nil) {
            let service = ATProtoService()
            await service.restoreSession()
            #expect(service.authPhase == .unauthenticated)
            #expect(!service.isAuthenticated)
            #expect(!service.isLoading)
        }
    }

    @Test func logoutLandsOnLogin() async {
        await withPlatform(lastHandle: nil) {
            let service = ATProtoService()
            await service.logout()
            #expect(service.authPhase == .unauthenticated)
            #expect(!service.isAuthenticated)
        }
    }
}
