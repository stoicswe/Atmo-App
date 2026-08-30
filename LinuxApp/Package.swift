// swift-tools-version: 6.0

// Linux front end for Atmo — Adwaita for Swift (GTK4/libadwaita) on top
// of the shared AtmoCore model layer (models, ATProtoService, stores,
// view models). Built and run on Linux; the Apple platforms keep their
// SwiftUI app (../Apple).
//
// adwaita-swift is tracked by branch because its release tags lag the
// generated-widget surface this app uses.
import PackageDescription

let package = Package(
    name: "AtmoLinux",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../AtmoCore"),
        .package(url: "https://git.aparoksha.dev/aparoksha/adwaita-swift", branch: "main"),
        // Fork override for the "swift-log" identity (see AtmoCore/Package.swift).
        .package(url: "https://github.com/stoicswe/swift-log.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "Atmo",
            dependencies: [
                .product(name: "AtmoCore", package: "AtmoCore"),
                .product(name: "Adwaita", package: "adwaita-swift"),
                // Raw GLib/GTK4/libadwaita headers for the main-loop
                // bridge (see MainLoopBridge.swift).
                .product(name: "CAdw", package: "adwaita-swift"),
                // Linked so the swift-log fork override counts as used.
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                // Adwaita for Swift predates strict concurrency: its View
                // protocol requirements are nonisolated, while AtmoCore's
                // service classes are @MainActor. GTK is strictly
                // single-threaded (everything runs on the main thread), so
                // the app bridges with MainActor.assumeIsolated (see
                // AppSession.onMain) and compiles in Swift 5 mode until
                // the toolkit adopts Swift 6 isolation.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Headless smoke test for the GLib ↔ Swift-concurrency bridge:
        // runs a GMainLoop with the RunLoop pump installed and verifies
        // that @MainActor tasks (the shape of every AtmoCore call) run
        // to completion. No display needed — run it in the dev container:
        //   swift run --scratch-path .build-linux AtmoSmoke
        .executableTarget(
            name: "AtmoSmoke",
            dependencies: [
                .product(name: "AtmoCore", package: "AtmoCore"),
                // Adwaita provides Idle for the pump — and linking CAdw
                // without it fails: adwshim.o always references the
                // @_cdecl dialog callbacks defined in the Adwaita module.
                .product(name: "Adwaita", package: "adwaita-swift"),
                .product(name: "CAdw", package: "adwaita-swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
