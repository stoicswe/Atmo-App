# Atmo

Atmo is a Bluesky (AT Protocol) client for **macOS, iOS, iPadOS, watchOS,
and Ubuntu Linux**, built on the
[ATProtoKit](https://github.com/MasterJ93/ATProtoKit) library.

## Layout

```
AtmoCore/      Platform-neutral model & service layer (SPM package).
               Models, ATProtoService, stores, view models. No UI
               imports — builds and tests on macOS and Linux.
Apple/         The SwiftUI app (macOS/iOS/iPadOS) and the watchOS app
               (Apple/Watch), plus the Apple implementations of
               AtmoCore's platform seams (Keychain, iCloud KVS,
               Spotlight) in Apple/Platform.
LinuxApp/      The GNOME app: GTK4/libadwaita via Adwaita for Swift, on
               the same AtmoCore. See LinuxApp/PORTING.md for the
               feature parity tracker and build instructions.
Resources/     Asset catalog, Info.plist fragment, entitlements.
project.yml    XcodeGen definition for Atmo.xcodeproj (targets: Atmo for
               iOS+macOS, AtmoWatch for watchOS).
snap/          Snapcraft packaging for the Ubuntu app.
```

## Building

**Apple platforms** — open `Atmo.xcodeproj` (or regenerate it after
editing `project.yml`):

```sh
xcodegen generate
```

Schemes: `Atmo` (iPhone/iPad/Mac), `AtmoWatch` (Apple Watch).

**Shared core** — pure SwiftPM, with tests:

```sh
cd AtmoCore && swift test
```

**Linux** — see [LinuxApp/PORTING.md](LinuxApp/PORTING.md) (dev
container for development, `snapcraft` for the Ubuntu package).

## Architecture

The rule that keeps five platforms maintainable: **AtmoCore is the source
of truth** for models, session management, and feed/notification/composer
logic. UI layers (SwiftUI and GTK) hold no business logic; anything
platform-specific AtmoCore needs (credential storage, synced key-value
store, search indexing, lifecycle notifications) is declared as a
protocol seam in `AtmoCore/Sources/AtmoCore/Platform` and installed at
launch via `Atmo.platform`.

Sessions use App Passwords via ATProtoKit's `ATProtocolConfiguration`
(`ATCredentialStore` + a stable session UUID persisted per install).
