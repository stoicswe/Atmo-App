import Foundation
import Testing
@testable import AtmoCore

struct FileCredentialStoreTests {

    private func makeStore() -> FileCredentialStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmo-cred-tests-\(UUID().uuidString)")
            .appendingPathComponent("credentials.json")
        return FileCredentialStore(fileURL: url)
    }

    @Test func roundTripsValues() async throws {
        let store = makeStore()
        let secret = Data("a-refresh-token".utf8)
        try await store.saveValue(secret, forKey: "uuid.refreshToken")
        let loaded = try await store.loadValue(forKey: "uuid.refreshToken")
        #expect(loaded == secret)
    }

    @Test func saveReplacesExistingValue() async throws {
        let store = makeStore()
        try await store.saveValue(Data("old".utf8), forKey: "k")
        try await store.saveValue(Data("new".utf8), forKey: "k")
        let loaded = try await store.loadValue(forKey: "k")
        #expect(loaded == Data("new".utf8))
    }

    @Test func deleteRemovesValueAndMissingDeleteSucceeds() async throws {
        let store = makeStore()
        try await store.saveValue(Data("v".utf8), forKey: "k")
        try await store.deleteValue(forKey: "k")
        let loaded = try await store.loadValue(forKey: "k")
        #expect(loaded == nil)
        // Deleting a missing value must be treated as success.
        try await store.deleteValue(forKey: "k")
    }

    @Test func missingKeyLoadsNil() async throws {
        let store = makeStore()
        let loaded = try await store.loadValue(forKey: "never-written")
        #expect(loaded == nil)
    }
}
