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
  state), including per-thread `ThreadSession`s (core `ThreadViewModel`
  + a seeded `TimelineViewModel` for like/repost); `onMain {}` bridges
  GTK's nonisolated callbacks onto `@MainActor` for synchronous reads.
- `MainView*.swift` — the shell; `@State` holds value snapshots only.
  Async work goes through `runCore { await … }`, which bumps `tick` on
  completion so the body re-reads model snapshots.
- `ModelObserver.swift` — Swift Observation → GTK bridge: re-renders
  when core models change on their own schedule (silent timeline
  refresh, search debounce). Registered once per sign-in.
- `ImageLoader.swift` — avatar/embed byte cache (memory + XDG disk) with
  `remoteAvatar` / `remotePicture` helpers; AtmoCore stays UI-free.
- `VideoPlayer.swift` — inline HLS playback: playbin3 →
  gtk4paintablesink → GtkPicture with a transport row (play/pause,
  seek slider, clock). libgstreamer is dlopen'd (no dev headers
  needed); rows show poster + play pill, tapping swaps the player in
  (`playingVideos` state), closing it tears the pipeline down.

## adwaita-swift gotchas (learned the hard way)

- **`.overlay {}` never materializes its main child** — the badge shows,
  the content vanishes. Don't use it; stack elements instead.
- **Modifiers chained onto a `Body` (view array) silently drop the
  content** in list rows. Builder helpers that get modifiers applied must
  return one concrete view (`AnyView`), not `Body`.
- **Swapping view *types* per render (placeholder ⇄ `Picture(data:)`)
  doesn't rebuild inside `ForEach` rows.** Remote images therefore keep
  one `GtkPicture` widget and install the texture imperatively via
  `.inspect` (see `remotePicture` / `remoteAvatar`), including an
  explicit `gtk_widget_set_size_request` height — a can-shrink picture
  otherwise collapses to 0 in these rows.
- `.inspect` must be chained onto the concrete widget *before* wrappers
  like `.frame` (Clamp), or the closure gets the wrapper's storage.

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
