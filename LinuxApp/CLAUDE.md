# LinuxApp — working notes

GTK4/libadwaita front end for Atmo via [Adwaita for Swift]
(https://git.aparoksha.dev/aparoksha/adwaita-swift), on the shared
`AtmoCore` package. Read `PORTING.md` first — it is the feature spec and
parity tracker.

## Rules

- **Never re-implement model/service logic here.** If the UI needs logic
  that doesn't exist in AtmoCore, add it to AtmoCore with public API and
  tests, then use it from here (and from the SwiftUI app when relevant).
- The behavioral reference is the SwiftUI app under `../Apple/`.
- Update `PORTING.md`'s parity matrix in the same change that lands a
  feature.

## Architecture cheat-sheet

- `Main.swift` — `AdwaitaApp`, single window.
- `MainLoopBridge.swift` — the GLib timeout that pumps `RunLoop.main` so
  `@MainActor` jobs run while `g_application_run` owns the main thread.
  Without it every `await` on AtmoCore hangs. `AtmoSmoke` (headless)
  proves the bridge works: `swift run AtmoSmoke` in the dev container.
- `AppSession.swift` — owns `ATProtoService` + view models (reference
  state); `onMain {}` bridges GTK's nonisolated callbacks onto
  `@MainActor` for synchronous reads.
- `MainView*.swift` — the shell; `@State` holds value snapshots only.
  Async work goes through `runCore { await … }`, which bumps `tick` on
  completion so the body re-reads model snapshots.

## Build

See PORTING.md §5 (dev container; snapcraft for release). There is no
GTK on macOS — this package only builds on Linux.

## Concurrency contract

- GTK is single-threaded; everything UI runs on the main thread.
- Adwaita's `View` protocol is nonisolated; AtmoCore is `@MainActor`.
  Bridge with `onMain {}` (sync) / `runCore {}` (async). Never call
  `MainActor.assumeIsolated` off the main thread.
- Compile stays in Swift 5 language mode until the toolkit adopts
  Swift 6 isolation.
