import Foundation
import Crypto

// MARK: - WalletPassBuilder
/// Assembles a `.pkpass`: `pass.json`, the image files, a `manifest.json`
/// of SHA-1 hashes over all of them, and the detached signature of that
/// manifest — zipped. Everything but the signature is deterministic.
public struct WalletPassBuilder: Sendable {

    /// Image file names Wallet reads for the profile pass. The classic
    /// layout wants `logo`; the iOS 27 poster layout wants `primaryLogo`
    /// and the full-card `artwork`; `icon` shows in notifications and
    /// Mail on every layout. All at @2x and @3x (plus @1x for the icon).
    public enum Asset {
        public static let icon = ["icon.png", "icon@2x.png", "icon@3x.png"]
        public static let logo = ["logo@2x.png", "logo@3x.png"]
        public static let primaryLogo = ["primaryLogo@2x.png", "primaryLogo@3x.png"]
        public static let artwork = ["artwork@2x.png", "artwork@3x.png"]
        /// Without these the pass is rejected or shows blank.
        public static let required = icon + primaryLogo + artwork
    }

    public let signer: any PassSigning

    public init(signer: any PassSigning) {
        self.signer = signer
    }

    /// - Parameter assets: file name → PNG bytes (see `Asset`).
    public func build(document: WalletPassDocument, assets: [String: Data]) throws -> Data {
        for name in Asset.required where assets[name] == nil {
            throw WalletPassError.missingAsset(name)
        }
        var files = assets
        files["pass.json"] = try document.jsonData()

        let manifest = try Self.manifest(for: files)
        let signature = try signer.sign(manifest: manifest)

        var entries = files.keys.sorted().map { ZipArchiveWriter.Entry(name: $0, data: files[$0]!) }
        entries.append(ZipArchiveWriter.Entry(name: "manifest.json", data: manifest))
        entries.append(ZipArchiveWriter.Entry(name: "signature", data: signature))
        return ZipArchiveWriter.archive(entries)
    }

    /// `manifest.json`: every file's SHA-1 hex digest, keyed by name.
    /// SHA-1 is what the pass format specifies, not a choice.
    public static func manifest(for files: [String: Data]) throws -> Data {
        var digests: [String: String] = [:]
        for (name, data) in files {
            digests[name] = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(digests)
    }
}
