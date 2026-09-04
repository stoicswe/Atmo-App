import Foundation
import Testing
import Crypto
import _CryptoExtras
import SwiftASN1
@_spi(CMS) import X509
@testable import AtmoCore

// MARK: - Test signer
/// A throwaway Pass Type ID-shaped certificate: self-signed RSA with the
/// same subject attributes Apple issues (UID = pass type id, OU = team).
private struct TestPassIdentity {
    let certificate: Certificate
    let certificatePEM: String
    let privateKeyPEM: String
    static let passType = "pass.test.atmo"
    static let team = "TEAM123456"

    init() throws {
        let rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let key = Certificate.PrivateKey(rsa)
        let subject = DistinguishedName([
            RelativeDistinguishedName(.init(type: LocalCMSPassSigner.userIDOID, utf8String: Self.passType)),
            RelativeDistinguishedName(.init(type: .RDNAttributeType.commonName, utf8String: "Pass Type ID: \(Self.passType)")),
            RelativeDistinguishedName(.init(type: .RDNAttributeType.organizationalUnitName, utf8String: Self.team)),
            RelativeDistinguishedName(.init(type: .RDNAttributeType.organizationName, utf8String: "Atmo Tests")),
        ])
        let now = Date()
        certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(3600),
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: Certificate.Extensions {},
            issuerPrivateKey: key
        )
        certificatePEM = try certificate.serializeAsPEM().pemString
        privateKeyPEM = rsa.pemRepresentation
    }
}

private func sampleAssets() -> [String: Data] {
    var assets: [String: Data] = [:]
    for name in WalletPassBuilder.Asset.required {
        assets[name] = Data(name.utf8)
    }
    return assets
}

// MARK: - ZIP

struct ZipArchiveWriterTests {

    @Test func crc32MatchesReferenceVector() {
        // The CRC-32 check value from the spec.
        #expect(ZipArchiveWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipArchiveWriter.crc32(Data()) == 0)
    }

    @Test func archiveLayoutIsWellFormedAndDeterministic() throws {
        let entries = [
            ZipArchiveWriter.Entry(name: "pass.json", data: Data("{}".utf8)),
            ZipArchiveWriter.Entry(name: "icon.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
        ]
        let a = ZipArchiveWriter.archive(entries)
        let b = ZipArchiveWriter.archive(entries)
        #expect(a == b)

        // Local header signature first, end-of-central-directory last.
        #expect(Array(a.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
        let eocd = a.suffix(22)
        #expect(Array(eocd.prefix(4)) == [0x50, 0x4B, 0x05, 0x06])
        // Entry count (twice), central directory size and offset.
        let count = UInt16(eocd[eocd.startIndex + 8]) | UInt16(eocd[eocd.startIndex + 9]) << 8
        #expect(count == 2)
        // Stored entries carry their bytes verbatim.
        #expect(a.range(of: Data("{}".utf8)) != nil)
        #expect(a.range(of: Data("icon.png".utf8)) != nil)
    }

    /// `unzip -t` (where the machine has it) is the real arbiter of
    /// whether another reader accepts the archive.
    @Test func systemUnzipAcceptsArchive() throws {
        let unzip = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzip) else { return }
        let archive = ZipArchiveWriter.archive([
            ZipArchiveWriter.Entry(name: "pass.json", data: Data("{\"formatVersion\":1}".utf8)),
            ZipArchiveWriter.Entry(name: "manifest.json", data: Data("{}".utf8)),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atmo-\(UUID().uuidString).pkpass")
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: unzip)
        process.arguments = ["-tqq", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

// MARK: - pass.json

struct WalletPassDocumentTests {

    private func makeDocument(memberSince: Date? = Date(timeIntervalSince1970: 1_737_849_600)) -> WalletPassDocument {
        WalletPassDocument.profile(
            handle: "alice.bsky.social",
            did: "did:plc:abc123",
            memberSince: memberSince,
            theme: .sky,
            passTypeIdentifier: "pass.test.atmo",
            teamIdentifier: "TEAM123456",
            appStoreID: 123
        )
    }

    @Test func profileDocumentCarriesIdentityAndQR() throws {
        let doc = makeDocument()
        #expect(doc.serialNumber == "did:plc:abc123")
        #expect(doc.barcodes.first?.message == "https://bsky.app/profile/alice.bsky.social")
        #expect(doc.barcodes.first?.altText == "alice.bsky.social")
        #expect(doc.barcodes.first?.format == "PKBarcodeFormatQR")
        #expect(doc.posterGeneric.primaryFields.map(\.key) == ["handle", "since"])
        #expect(doc.posterGeneric.footerFields?.first?.value == "did:plc:abc123")
        #expect(doc.generic.primaryFields.first?.value == "alice.bsky.social")
        #expect(doc.generic.footerFields == nil)
        #expect(doc.backgroundColor == "rgb(36, 118, 214)")
        #expect(doc.associatedStoreIdentifiers == [123])
    }

    @Test func memberSinceIsOptionalAndISO8601() throws {
        let with = makeDocument()
        let since = try #require(with.posterGeneric.primaryFields.last)
        #expect(since.dateStyle == "PKDateStyleShort")
        #expect(since.value == "2025-01-26T00:00:00Z")

        let without = makeDocument(memberSince: nil)
        #expect(without.posterGeneric.primaryFields.map(\.key) == ["handle"])
        #expect(without.generic.secondaryFields.isEmpty)
    }

    @Test func jsonIsDeterministicAndUnescaped() throws {
        let data = try makeDocument().jsonData()
        let again = try makeDocument().jsonData()
        #expect(data == again)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"formatVersion\":1"))
        #expect(text.contains("https://bsky.app/profile/alice.bsky.social"))
        #expect(!text.contains("\\/"))
        // Absent optionals are omitted, not written as null.
        #expect(!text.contains("null"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["generic"] != nil)
        #expect(object["posterGeneric"] != nil)
    }

    /// The app reads `Resources/WalletPass/Themes/<id>/artwork@2x|3x.png`
    /// by theme id; a theme without artwork would build a pass Wallet
    /// rejects. Checked against the repo checkout when it's present.
    @Test func everyBuiltInThemeHasArtworkInTheRepo() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let themes = repoRoot.appendingPathComponent("Resources/WalletPass/Themes")
        guard FileManager.default.fileExists(atPath: themes.path) else { return }
        for theme in WalletPassTheme.builtIn {
            for name in WalletPassBuilder.Asset.artwork {
                let file = themes.appendingPathComponent(theme.id).appendingPathComponent(name)
                #expect(FileManager.default.fileExists(atPath: file.path), "\(theme.id) is missing \(name)")
            }
        }
    }

    @Test func themesHaveUniqueIDs() {
        let ids = WalletPassTheme.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(WalletPassTheme.builtIn(id: "sky") == .sky)
        #expect(WalletPassTheme.RGB(1, 2, 3).cssString == "rgb(1, 2, 3)")
    }
}

// MARK: - Signing and assembly

struct WalletPassSigningTests {

    @Test func signerReadsIdentifiersFromCertificateSubject() throws {
        let identity = try TestPassIdentity()
        let signer = try LocalCMSPassSigner(certificatePEM: identity.certificatePEM, privateKeyPEM: identity.privateKeyPEM, intermediatePEMs: [])
        #expect(signer.passTypeIdentifier == TestPassIdentity.passType)
        #expect(signer.teamIdentifier == TestPassIdentity.team)
    }

    @Test func rejectsGarbageCredentials() throws {
        let identity = try TestPassIdentity()
        #expect(throws: WalletPassError.self) {
            try LocalCMSPassSigner(certificatePEM: "not a cert", privateKeyPEM: identity.privateKeyPEM, intermediatePEMs: [])
        }
        #expect(throws: WalletPassError.self) {
            try LocalCMSPassSigner(certificatePEM: identity.certificatePEM, privateKeyPEM: "not a key", intermediatePEMs: [])
        }
    }

    @Test func detachedSignatureVerifiesAgainstCertificate() async throws {
        let identity = try TestPassIdentity()
        let signer = try LocalCMSPassSigner(certificatePEM: identity.certificatePEM, privateKeyPEM: identity.privateKeyPEM, intermediatePEMs: [])
        let manifest = Data("{\"pass.json\":\"00\"}".utf8)
        let signature = try signer.sign(manifest: manifest)
        #expect(!signature.isEmpty)
        // Detached: the manifest bytes are not embedded in the blob.
        #expect(signature.range(of: manifest) == nil)

        let result = try await CMS.isValidSignature(dataBytes: manifest, signatureBytes: signature, trustRoots: CertificateStore([identity.certificate])) {}
        guard case .success = result else {
            Issue.record("signature did not verify: \(result)")
            return
        }
        // A tampered manifest must fail.
        let tampered = try await CMS.isValidSignature(dataBytes: Data("{}".utf8), signatureBytes: signature, trustRoots: CertificateStore([identity.certificate])) {}
        guard case .failure = tampered else {
            Issue.record("tampered manifest verified")
            return
        }
    }

    @Test func manifestHashesEveryFileWithSHA1() throws {
        let manifest = try WalletPassBuilder.manifest(for: ["pass.json": Data("abc".utf8), "icon.png": Data()])
        let object = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: String])
        #expect(object["pass.json"] == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(object["icon.png"] == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(object.count == 2)
    }

    @Test func builderProducesCompletePass() throws {
        let identity = try TestPassIdentity()
        let signer = try LocalCMSPassSigner(certificatePEM: identity.certificatePEM, privateKeyPEM: identity.privateKeyPEM, intermediatePEMs: [])
        let document = WalletPassDocument.profile(
            handle: "alice.bsky.social", did: "did:plc:abc123", memberSince: nil, theme: .dusk,
            passTypeIdentifier: signer.passTypeIdentifier, teamIdentifier: signer.teamIdentifier
        )
        let pass = try WalletPassBuilder(signer: signer).build(document: document, assets: sampleAssets())
        #expect(Array(pass.prefix(2)) == [0x50, 0x4B])
        for name in ["pass.json", "manifest.json", "signature"] + WalletPassBuilder.Asset.required {
            #expect(pass.range(of: Data(name.utf8)) != nil, "missing \(name)")
        }
    }

    @Test func builderRefusesIncompleteAssets() throws {
        let identity = try TestPassIdentity()
        let signer = try LocalCMSPassSigner(certificatePEM: identity.certificatePEM, privateKeyPEM: identity.privateKeyPEM, intermediatePEMs: [])
        let document = WalletPassDocument.profile(handle: "a", did: "did:plc:a", memberSince: nil, theme: .sky, passTypeIdentifier: "p", teamIdentifier: "t")
        var assets = sampleAssets()
        assets["artwork@3x.png"] = nil
        #expect(throws: WalletPassError.missingAsset("artwork@3x.png")) {
            try WalletPassBuilder(signer: signer).build(document: document, assets: assets)
        }
    }
}
