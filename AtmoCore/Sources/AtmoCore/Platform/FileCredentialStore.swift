import Foundation
import ATProtoKit

/// File-backed implementation of ATProtoKit's `ATCredentialStore` for
/// platforms without a system keychain (Linux) and for tests.
///
/// Values are kept in a single JSON file (base64-encoded per key) under
/// the platform's application-support directory with `0600` permissions,
/// mirroring what most Linux applications do when libsecret is not
/// available. The Linux app can later swap in a libsecret-backed store
/// without touching this API — see LinuxApp/PORTING.md.
/// A credential store that can list the keys it holds. Session recovery
/// uses it to find a stored App Password even when the install's stable
/// session UUID rotated away from the namespace the credential was saved
/// under (see `ATProtoService.reauthenticateFromStoredCredential`).
public protocol EnumerableCredentialStore {
    func allKeys() async throws -> [String]
}

public actor FileCredentialStore: ATCredentialStore, EnumerableCredentialStore {

    public func allKeys() async throws -> [String] {
        Array(readAll().keys)
    }

    private let fileURL: URL

    /// - Parameter fileURL: Override for tests. Defaults to
    ///   `<application support>/Atmo/credentials.json`.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("Atmo", isDirectory: true)
                .appendingPathComponent("credentials.json")
        }
    }

    public func loadValue(forKey key: String) async throws -> Data? {
        readAll()[key].flatMap { Data(base64Encoded: $0) }
    }

    public func saveValue(_ value: Data, forKey key: String) async throws {
        var all = readAll()
        all[key] = value.base64EncodedString()
        try writeAll(all)
    }

    public func deleteValue(forKey key: String) async throws {
        var all = readAll()
        // Deleting a missing value is success by the ATCredentialStore contract.
        guard all.removeValue(forKey: key) != nil else { return }
        try writeAll(all)
    }

    // MARK: - Private

    private func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private func writeAll(_ values: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(values)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
