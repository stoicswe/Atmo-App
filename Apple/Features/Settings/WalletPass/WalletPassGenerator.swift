#if os(iOS)
import Foundation
import PassKit
import AtmoCore

// MARK: - WalletPassCredentials
/// The Pass Type ID material bundled under `WalletPass/Signing/` in the
/// app: `pass.pem` (certificate), `pass-key.pem` (its RSA key), and
/// Apple's `AppleWWDRCAG4.pem` intermediate. The first two are per-
/// developer and gitignored — see the README in that folder — so a build
/// without them simply has no signer and Settings hides the feature.
nonisolated enum WalletPassCredentials {
    static let subdirectory = "WalletPass/Signing"

    /// Parsed once. Nil when the certificate or key isn't in this build
    /// (or doesn't parse — the reason is logged).
    static let signer: LocalCMSPassSigner? = load()

    private static func load() -> LocalCMSPassSigner? {
        guard let certificate = pem("pass"), let key = pem("pass-key") else { return nil }
        let intermediates = pem("AppleWWDRCAG4").map { [$0] } ?? []
        do {
            return try LocalCMSPassSigner(certificatePEM: certificate, privateKeyPEM: key, intermediatePEMs: intermediates)
        } catch {
            NSLog("WalletPass: signing credentials present but unusable: \(error)")
            return nil
        }
    }

    private static func pem(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "pem", subdirectory: subdirectory) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - WalletPassAvailability
/// Whether Settings should offer the pass at all: this device has Wallet
/// (iPhone; iPad and Mac don't), and the build can sign. Debug builds
/// still show the row without credentials so the missing setup is
/// visible instead of silently absent.
enum WalletPassAvailability {
    static var canSign: Bool { WalletPassCredentials.signer != nil }

    static var canOffer: Bool {
        guard PKAddPassesViewController.canAddPasses() else { return false }
#if DEBUG
        return true
#else
        return canSign
#endif
    }
}

// MARK: - WalletPassGenerator
/// Gathers the bundled images for a theme and hands everything to
/// AtmoCore's builder. Pure file reads and CPU work — call off the main
/// actor.
nonisolated enum WalletPassGenerator {
    static let imagesSubdirectory = "WalletPass"

    /// The finished `.pkpass` bytes for the signed-in account.
    static func makePass(handle: String, did: String, memberSince: Date?, theme: WalletPassTheme, signer: LocalCMSPassSigner) throws -> Data {
        let document = WalletPassDocument.profile(
            handle: handle,
            did: did,
            memberSince: memberSince,
            theme: theme,
            passTypeIdentifier: signer.passTypeIdentifier,
            teamIdentifier: signer.teamIdentifier
        )
        return try WalletPassBuilder(signer: signer).build(document: document, assets: try assets(for: theme))
    }

    /// Every image the pass carries: shared icon/logos plus the theme's
    /// artwork, keyed by the file name Wallet expects.
    static func assets(for theme: WalletPassTheme) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in WalletPassBuilder.Asset.icon + WalletPassBuilder.Asset.logo + WalletPassBuilder.Asset.primaryLogo {
            files[name] = try read(name, subdirectory: imagesSubdirectory)
        }
        for name in WalletPassBuilder.Asset.artwork {
            files[name] = try read(name, subdirectory: themeSubdirectory(theme))
        }
        return files
    }

    static func themeSubdirectory(_ theme: WalletPassTheme) -> String {
        "\(imagesSubdirectory)/Themes/\(theme.id)"
    }

    /// The @3x artwork, for the in-app preview.
    static func artworkURL(for theme: WalletPassTheme) -> URL? {
        url("artwork@3x.png", subdirectory: themeSubdirectory(theme))
    }

    static func primaryLogoURL() -> URL? {
        url("primaryLogo@3x.png", subdirectory: imagesSubdirectory)
    }

    private static func url(_ fileName: String, subdirectory: String) -> URL? {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return Bundle.main.url(forResource: base, withExtension: ext, subdirectory: subdirectory)
    }

    private static func read(_ fileName: String, subdirectory: String) throws -> Data {
        guard let url = url(fileName, subdirectory: subdirectory) else {
            throw WalletPassError.missingAsset("\(subdirectory)/\(fileName)")
        }
        return try Data(contentsOf: url)
    }
}
#endif
