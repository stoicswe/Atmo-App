# Atmo — working notes

Bluesky client for macOS / iOS / iPadOS / watchOS / Ubuntu. Same
structure and rules as the {m.txt} editor repo (`../minimalist`), which
this porting technique comes from.

## The one rule

**AtmoCore is the source of truth.** Models, session management, and
feed/notification/composer/search logic live in `AtmoCore/` (platform-
neutral SPM package, Swift 6 strict mode, no UI imports — Foundation,
Observation, and ATProtoKit only). UI layers reuse it; when logic is
missing, extend AtmoCore with public API + tests instead of implementing
in a view layer. AtmoCore must keep passing `swift test` on macOS *and*
Linux (dev container: `LinuxApp/dev-container`).

Platform-specific tech is reached through the seams in
`AtmoCore/Sources/AtmoCore/Platform/AtmoPlatform.swift`
(secrets/keychain, synced KV store, search indexing, credential store,
lifecycle notification). Apple implementations: `Apple/Platform/`;
installed via `Atmo.platform = .apple` in each app's `init()`.

## Editing the Xcode project

`Atmo.xcodeproj` is generated — edit `project.yml`, then:

```sh
xcodegen generate
```

Both are committed. Don't hand-edit the pbxproj.

## Verification matrix (run what your change touches)

```sh
cd AtmoCore && swift test                          # core, macOS
docker run --rm -v "$PWD:/src" -w /src/AtmoCore swift:6.2 \
  swift test --scratch-path .build-linux           # core, Linux
xcodebuild -project Atmo.xcodeproj -scheme Atmo -destination platform=macOS \
  CODE_SIGNING_ALLOWED=NO build                    # app, macOS
xcodebuild -project Atmo.xcodeproj -scheme Atmo \
  -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Atmo.xcodeproj -scheme AtmoWatch \
  -destination generic/platform=watchOS CODE_SIGNING_ALLOWED=NO build
```

Linux app: see `LinuxApp/CLAUDE.md` and `LinuxApp/PORTING.md` (keep the
parity matrix updated when landing Linux features).

## Auth/session invariants (don't break these)

- `KeychainSecretsStore` keys (`com.atmo.app` service, stable session
  UUID) and ATProtoKit's default `AppleSecureKeychain` service name
  (`"ATProtoKit"`) must stay unchanged — together they keep existing
  installs' refresh tokens working (`<uuid>.refreshToken`).
- Bundle ID `stoicswe.com-atmin-app` and the keychain access group in
  `Resources/Atmo.entitlements` likewise.

## Wallet profile pass (iOS 27+)

Settings → Account → "Add to Apple Wallet" builds a `.pkpass` on the
device: `AtmoCore/Sources/AtmoCore/Services/WalletPass/` (pass.json
model, SHA-1 manifest, stored-ZIP writer, CMS signer via
swift-certificates' `@_spi(CMS)`), presented by
`Apple/Features/Settings/WalletPass/`. Images and signing material are a
folder reference, `Resources/WalletPass/` (themes under `Themes/<id>/`
— swap the placeholder PNGs for stock artwork). The Pass Type ID
certificate and key are gitignored; setup in
`Resources/WalletPass/Signing/README.md`. Without them release builds
hide the row and debug builds show it disabled.
