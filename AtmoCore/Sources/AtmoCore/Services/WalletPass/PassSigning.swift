import Foundation
import Crypto
import _CryptoExtras
import SwiftASN1
@_spi(CMS) import X509

// MARK: - PassSigning
/// Produces the detached PKCS#7 (CMS) signature Wallet checks over a
/// pass's `manifest.json`. The signature must come from the Pass Type ID
/// certificate the pass names, so a signer also knows the identifiers the
/// `pass.json` has to carry.
public protocol PassSigning: Sendable {
    /// `pass.xxx` — the Pass Type ID the certificate was issued for.
    var passTypeIdentifier: String { get }
    /// The Apple Developer team that owns it.
    var teamIdentifier: String { get }
    func sign(manifest: Data) throws -> Data
}

public enum WalletPassError: Error, LocalizedError, Sendable, Equatable {
    /// The signing certificate/key aren't in this build.
    case credentialsUnavailable
    case invalidCertificate(String)
    case invalidPrivateKey(String)
    /// The certificate subject lacks the Pass Type ID (UID) or team (OU).
    case certificateSubjectIncomplete
    case signingFailed(String)
    case missingAsset(String)

    public var errorDescription: String? {
        switch self {
        case .credentialsUnavailable: return "Wallet pass signing credentials aren't available in this build."
        case .invalidCertificate(let why): return "The pass certificate couldn't be read: \(why)"
        case .invalidPrivateKey(let why): return "The pass signing key couldn't be read: \(why)"
        case .certificateSubjectIncomplete: return "The pass certificate doesn't name a Pass Type ID and team."
        case .signingFailed(let why): return "Signing the pass failed: \(why)"
        case .missingAsset(let name): return "The pass is missing the image \(name)."
        }
    }
}

// MARK: - LocalCMSPassSigner
/// Signs on the device with a Pass Type ID certificate and its RSA key
/// (PEM), chaining Apple's WWDR intermediate so Wallet can verify. The
/// identifiers are read from the certificate subject Apple issues —
/// `UID` is the Pass Type ID, `OU` the team — so they can never disagree
/// with the key doing the signing.
///
/// The key ships inside the app, which means it can be extracted; all it
/// can do is mint passes under this Pass Type ID, and Apple lets the
/// certificate be revoked and reissued.
public struct LocalCMSPassSigner: PassSigning {
    private let certificate: Certificate
    private let intermediates: [Certificate]
    private let privateKey: Certificate.PrivateKey
    public let passTypeIdentifier: String
    public let teamIdentifier: String

    /// Apple's `UID` attribute (RFC 1274 userId), which the Pass Type ID
    /// certificate subject carries.
    static let userIDOID: ASN1ObjectIdentifier = "0.9.2342.19200300.100.1.1"

    public init(certificatePEM: String, privateKeyPEM: String, intermediatePEMs: [String]) throws {
        let certificate: Certificate
        do {
            certificate = try Certificate(pemEncoded: certificatePEM)
        } catch {
            throw WalletPassError.invalidCertificate(String(describing: error))
        }
        do {
            // Pass Type ID keys are RSA; _CryptoExtras reads both the
            // PKCS#1 ("RSA PRIVATE KEY") and PKCS#8 ("PRIVATE KEY") PEM forms.
            let rsa = try _RSA.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
            self.privateKey = Certificate.PrivateKey(rsa)
        } catch {
            throw WalletPassError.invalidPrivateKey(String(describing: error))
        }
        do {
            self.intermediates = try intermediatePEMs.map { try Certificate(pemEncoded: $0) }
        } catch {
            throw WalletPassError.invalidCertificate(String(describing: error))
        }
        self.certificate = certificate

        guard let passType = Self.subjectValue(certificate.subject, type: Self.userIDOID),
              let team = Self.subjectValue(certificate.subject, type: .RDNAttributeType.organizationalUnitName) else {
            throw WalletPassError.certificateSubjectIncomplete
        }
        self.passTypeIdentifier = passType
        self.teamIdentifier = team
    }

    public func sign(manifest: Data) throws -> Data {
        do {
            let bytes = try CMS.sign(
                manifest,
                additionalIntermediateCertificates: intermediates,
                certificate: certificate,
                privateKey: privateKey,
                signingTime: Date(),
                detached: true
            )
            return Data(bytes)
        } catch {
            throw WalletPassError.signingFailed(String(describing: error))
        }
    }

    static func subjectValue(_ name: DistinguishedName, type: ASN1ObjectIdentifier) -> String? {
        for rdn in name {
            for attribute in rdn where attribute.type == type {
                let value = String(describing: attribute.value)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
