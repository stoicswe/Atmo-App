# Porting Atmo to Linux — feature spec & parity tracker

The SwiftUI app (repo `Apple/`) is the reference implementation. The goal
is for the Linux app to feel like the same product: same features, same
behaviors — translated into GNOME idioms where a literal copy would fight
the platform (header bars, Ctrl instead of ⌘, GNOME's completion and
dialog conventions). This document describes the Apple app as it exists
today, tracks parity status, and maps each feature to its Linux
implementation strategy.

**Keep the matrix in this file updated as features land.**

The golden rule (same as the {m.txt} editor this technique comes from):
**AtmoCore is the source of truth** for models, session management, and
feed/notification/composer/search logic. Port by *reusing* it; extend it
(public API + tests) when logic is missing, rather than re-implementing in
the UI layer. It must never import UI frameworks and must keep passing
`swift test` on both OSes.

---

## 1. The Apple app, as shipped

### 1.1 Structure

- **Auth**: handle + App Password sign-in with optional email 2FA
  (`ATProtoService.login/submitTwoFactorCode/restoreSession/logout`).
  Session restore happens silently at launch via the stored refresh token.
- **Navigation**: sidebar/tab navigation between Timeline, Search,
  Notifications, DMs, Bookmarks, Drafts, Profile, Settings
  (`Apple/Navigation/AppNavigation.swift`).
- **Timeline** (`TimelineViewModel`): 50-post pages, infinite scroll,
  pull-to-refresh, silent periodic background refresh (60 s on macOS,
  180 s on iOS) with a "new posts" pill + avatar stack and scroll-position
  anchoring, thread-context dedup, like/repost with optimistic updates
  and rollback.
- **Threads** (`ThreadView`): root + parents + replies, inline reply
  composer with optimistic pending rows.
- **Composer** (`ComposerViewModel`): multi-post threads (slots), image
  attachments (up to 4, with alt text), reply/quote context, 300-char
  limit per slot, debounced draft autosave (`DraftStore`), Apple
  Intelligence translation disclosure toggle.
- **Search** (`SearchViewModel`): debounced posts + people + hashtag
  search with 5-minute idle auto-clear.
- **Notifications** (`NotificationsViewModel`): list, unread count,
  mark-seen on load.
- **DMs** (`DMsViewModel`, `ConversationDetailViewModel`): conversation
  list, message history, send.
- **Profiles** (`ProfileViewModel`): view/edit own profile (display name,
  bio, avatar), follow/unfollow with rollback, author feed.
- **Bookmarks** (`BookmarkStore`): local + iCloud-KVS dual-write,
  Spotlight donation, swipe-delete.
- **Position sync** (`PositionStore`): timeline read position via iCloud
  KVS.
- **Drafts** (`DraftStore`): resumable composer drafts in UserDefaults.
- **Design system**: glass cards, tints, custom fonts
  (`Apple/DesignSystem`) — macOS/iOS-distinctive; the Linux app uses
  stock Adwaita styling instead.

### 1.2 Keyboard shortcuts (macOS ⌘ ⇒ Linux Ctrl unless noted)

| macOS | Action | Linux |
|---|---|---|
| ⌘N | New post | Ctrl+N ✓ |
| ⌘R | Refresh | Ctrl+R ✓ |
| ⌘Q | Quit | Ctrl+Q ✓ (`quitShortcut`) |

## 2. Parity matrix

Status: ✅ done · 🟡 partial · ⬜ not started · ❌ intentionally skipped

| Feature | Linux status | Linux implementation |
|---|---|---|
| Sign-in (handle + App Password) | ✅ | `MainView+Login` on shared `ATProtoService`; same handle normalization as `AuthViewModel` |
| Email 2FA | ✅ | Extra `EntryRow` + `receiveCodeFromUser` when the service reports `requiresTwoFactor` |
| Session restore / logout | ✅ | `restoreSession()` on launch; primary-menu Sign Out |
| Credential storage | 🟡 | Core `FileCredentialStore` (0600 JSON under XDG app-support). **TODO:** libsecret-backed `SecretsStoring`/`ATCredentialStore` for keyring-grade storage |
| Timeline (pages, refresh, like, repost) | ✅ | `MainView+Timeline` on shared `TimelineViewModel` — thread-slice collapse, optimistic updates, and rollback come from core for free |
| Reply context in timeline rows | 🟡 | Core embeds the root/parent as `PostItem.threadAncestors`; Linux shows a "↩ Replying to …" line. **TODO:** render the ancestors as full inline rows with a rail, like the Apple feed |
| Infinite scroll | 🟡 | **Deviation (for now):** a "Load More" button. adwaita-swift's `edgeReached` fires for *every* edge without saying which, so hooking it would fetch pages whenever the user hits the *top*. Needs a position-aware `edge-reached` connection (via CAdw in `.inspect`) honoring core `FeedPreferences.infiniteScrollEnabled` |
| New-posts pill + scroll anchoring | ⬜ | Core exposes the full live-draining model (`newPostsCount`, `newPostAuthors`, `newPostsOverflowAuthorCount`, `markNewPostSeen`); needs a GTK overlay + ScrolledWindow adjustment work |
| Thread view | ⬜ | Core `PostItem` carries reply URIs; needs a `NavigationView` push page |
| Composer (single post) | ✅ | `.dialog` with `TextEditor`, 300-char counter, `createPostRecord` |
| Composer (threads, images, reply/quote) | ⬜ | Reuse `ComposerViewModel` + `PostSlot`; image picking via portal `fileImporter` |
| Drafts | ⬜ | `DraftStore` works on Linux already (UserDefaults → XDG plist); needs UI |
| Search (posts/people/hashtags/feeds) | ⬜ | Reuse `SearchViewModel` (`feedResults` + `loadMoreFeeds` for public feeds by name); GNOME `SearchEntry` in the header bar |
| Notifications list + mark-seen | ✅ | `MainView+Notifications` on shared `NotificationsViewModel` |
| Search history suggestions (opt-in, Settings → Search) | ⬜ | Core: `SearchHistoryStore` (record on submit/result tap, `recent` for the pills); Linux needs the toggle + a pill row under the search entry |
| DMs | ⬜ | Reuse `DMsViewModel`/`ConversationDetailViewModel`; split-view page |
| Send post via DM (paperplane in the action row) | ⬜ | Core has it: `SendPostViewModel` (recent conversations + people, per-recipient send state); needs a GTK recipient picker |
| Shared posts in DMs open the post | ⬜ | Core: `MessageItem.embeddedRecord` / `embeddedPostURI`; Apple renders the quote card and navigates on tap |
| Action row on thread-context rows | ⬜ | `TimelineViewModel.livePost(uri:)` and like/repost now work for `threadAncestors`; Linux still shows the "↩ Replying to" line |
| Profiles (view/edit/follow) | ⬜ | Reuse `ProfileViewModel` |
| Profile ··· menu (copy link, search posts, hide reposts, mute, block, report) | ⬜ | Core has it all: `ProfileModel.bskyWebURL`, `SearchViewModel.activateAuthorSearch`, `HiddenRepostsStore` (feeds already filter), `ProfileViewModel.toggleMute/toggleBlock`, `ReportAccountViewModel` (4-step report → chosen labeler). Needs GTK menu + report dialog |
| Bookmarks | ⬜ | `BookmarkStore` runs on Linux (synced store falls back to local-only); needs UI |
| Timeline position sync | 🟡 | `PositionStore` persists locally (no iCloud on Linux — by design, the seam falls back) |
| Avatars / images in feed | ⬜ | `Avatar` + `Picture` widgets; needs an image loader (AtmoCore stays UI-free, so a small GTK-side cache) |
| Rich text facets (links, mentions, tags) | ⬜ | Pango markup from `PostItem.facets` |
| Spotlight donation | ❌ | Apple-only; the `PostIndexing` seam installs the no-op |
| Apple Intelligence translation | ❌ | Apple-only (`TranslationHelper` lives in `Apple/`) |
| Glass design system | ❌ | macOS-distinctive; stock Adwaita here |
| Push/background refresh | 🟡 | Foreground timer via shared `TimelineViewModel`; no system push on Linux |

## 3. What's left (ordered)

1. **Avatars and embedded images** in timeline rows (GTK-side async
   image cache feeding `Avatar`/`Picture`).
2. **Thread view** (push page on `NavigationView`).
3. **Full composer** — reuse `ComposerViewModel` (threads, images,
   reply/quote, drafts).
4. **Search page** and **profiles**.
5. **DMs**.
6. **libsecret credential store** replacing `FileCredentialStore`.
7. **New-posts pill** with scroll anchoring.

## 4. Engineering conventions (see also `CLAUDE.md` here)

- AtmoCore is the source of truth for models/session/feed logic. It must
  never import UI frameworks and must keep passing `swift test` on both
  OSes (`swift test` on macOS; the dev container on Linux).
- The SwiftUI app is the behavioral reference — when in doubt about an
  interaction detail, read the corresponding file under `Apple/`.
- UI state pattern on Linux: Adwaita `@State` holds value snapshots
  (`PostRowSnapshot` etc.); reference models live in `AppSession`; every
  synchronous core-model touch goes through `onMain {}`, and every async
  call goes through `MainView.runCore` (a `Task { @MainActor }` kept
  alive by `MainLoopBridge` — see that file for why the pump exists).
- After every async operation, bump `tick` so Adwaita re-reads the model
  snapshots; the models themselves are never `@State`.
- Keep deviations deliberate and listed — GNOME HIG wins on input
  conventions and chrome, the Apple app wins on feature semantics.

## 5. Building

```sh
# once
docker build -t atmo-linux-dev LinuxApp/dev-container

# compile
docker run --rm -v "$PWD:/src" -w /src/LinuxApp atmo-linux-dev \
  swift build --scratch-path .build-linux

# verify the GLib ↔ Swift-concurrency bridge (headless)
docker run --rm -v "$PWD:/src" -w /src/LinuxApp atmo-linux-dev \
  swift run --scratch-path .build-linux AtmoSmoke

# snap (on an Ubuntu machine with snapcraft)
snapcraft
```
