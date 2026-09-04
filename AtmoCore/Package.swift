// swift-tools-version: 6.0

// Platform-neutral model and service layer shared by every Atmo front
// end: the SwiftUI app (macOS / iOS / iPadOS / watchOS) and the Linux
// app (LinuxApp/, GTK4/libadwaita). Nothing in here may import SwiftUI,
// AppKit, UIKit, WatchKit, or any other UI framework — Foundation,
// Observation, and ATProtoKit only.
//
// Apple-only technologies (Keychain, iCloud key-value store, Spotlight)
// are reached through the seams in Sources/AtmoCore/Platform; each app
// target plugs in its own implementations at launch via `Atmo.platform`.
import PackageDescription

let package = Package(
    name: "AtmoCore",
    platforms: [
        // Floor for the @Observable macro and modern concurrency clocks;
        // the apps themselves target newer.
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "AtmoCore", targets: ["AtmoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/MasterJ93/ATProtoKit.git", from: "0.34.1"),
        // Fork override: swift-log is ATProtoKit's dependency, but declaring
        // the fork here (and in the other roots: project.yml, LinuxApp)
        // makes the whole graph resolve the "swift-log" identity to the
        // fork's main branch instead of apple/swift-log.
        .package(url: "https://github.com/stoicswe/swift-log.git", branch: "main"),
        // Wallet passes: the .pkpass signature is a CMS (PKCS#7) detached
        // signature over manifest.json. swift-certificates produces it
        // (its CMS API is @_spi(CMS), hence the pinned floor) and
        // swift-crypto supplies SHA-1 for the manifest and RSA for the
        // Pass Type ID key — both build on Linux too.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3")
    ],
    targets: [
        .target(
            name: "AtmoCore",
            dependencies: [
                .product(name: "ATProtoKit", package: "ATProtoKit"),
                // Linked explicitly so the fork override above counts as a
                // used dependency (SwiftPM warns otherwise); ATProtoKit logs
                // through it and AtmoCore may too.
                .product(name: "Logging", package: "swift-log"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto")
            ]
        ),
        .testTarget(
            name: "AtmoCoreTests",
            dependencies: ["AtmoCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
