# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Gravity Music** (Flutter package name `saragama` — successor to the older "Saragama" app) — a Flutter music player that streams audio from YouTube via `youtube_explode_dart`. Playback architecture is a Flutter port of **HarmonyMusic**; several files say "mirrors HarmonyMusic's X" — when in doubt about *why* something is structured a certain way, that's the reference implementation it was ported from.

**Android is the primary target, but Linux/Windows desktop is actively supported** (media_kit audio backend + MPRIS system integration, see `main.dart`). iOS/web folders exist but are unconfirmed.

## Commands

- `flutter pub get` — install dependencies
- `flutter run` — run on a connected device/emulator (or `-d linux` / `-d windows` for desktop)
- `flutter analyze` — static analysis (uses `flutter_lints`, see `analysis_options.yaml`)
- `flutter test` — run the test suite (`test/` — pure-Dart service logic + a widget test; the audio handler is never booted)
- `flutter test test/services/taste_profile_test.dart` — run a single test file
- `flutter build apk` — build Android release APK

## Design reference

`references/` holds the design system: `references/gravity_music/DESIGN.md` is the full spec ("Cinematic Dark" / glassmorphism, obsidian-black OLED palette, 30px backdrop blurs, floating "suspended" layout where no element touches screen edges). Each screen folder (`home/`, `library/`, `now_playing/`, `search/`) has a `code.html` Tailwind mockup + `screen.png`. The design tokens live in code as `AppColors` / `AppText` / `AppSpacing` in `lib/ui/app_theme.dart` and the glass primitives in `lib/ui/theme/glass.dart` — use those, not raw values.

## Architecture

### Backend is fully on-device (no remote API)

The app once used a hosted "SaraGama" API (a Render server wrapping `ytmusicapi`). That is **gone** — everything now runs on the device. The pivot point is **`YtMusicService`** (`services/yt_music_service.dart`), a client that calls music.youtube.com's internal `youtubei` endpoints directly (search with the "Songs" filter, `next`/radio for queues, and `browse` for album pages). It returns clean Art Tracks (real titles/artists/album + square `googleusercontent` art). Its response is a deeply-nested `…Renderer` tree parsed defensively, so one shape change doesn't discard the whole result. **`SearchService`, `AlbumService`, `RecommendationService`, `MixesService`, and `ImportService` are all thin layers over `YtMusicService`** — when "up next" or search behaves oddly, suspect the youtubei parsing here.

**Albums** ride the same client: `searchAlbums(query)` uses the "Albums" filter param (the songs param with the type byte flipped) and returns `YtMusicAlbum` *headers* only — a browseId (`MPREb_…`), title, artist, year, cover. Tracks are resolved lazily by `albumDetail(browseId)`, which browses the album page. Album track rows commonly omit their own thumbnail and list the artist as plain text (no `pageType`), so the parser falls back to the album-level cover/artist and reads duration from `fixedColumns`. **`AlbumService`** (`services/album_service.dart`) wraps this with a 24h `CacheBox` entry and models tracks as `SearchResult`, so they reuse the existing `toMediaItem()` adapter and need no new playback plumbing.

### Playback stack

Split into focused layers, each single-responsibility — read the file-header comments in `lib/services/` before modifying; they document *why* the split exists:

- **`MyAudioHandler`** (`services/audio_handler.dart`) — the `audio_service`-facing layer (notification/lockscreen/MPRIS contract). Owns `queue`/`mediaItem`/`playbackState` subjects and the **`customAction` command bus** — all complex operations (`playByIndex`, `setSourceNPlay`, `playAllFrom`, `playShuffled`, `restoreSession`, `reorderQueue`, `addPlayNextItem`, `clearQueue`, etc.) are dispatched through `customAction(name, extras)` rather than dedicated methods. UI talks to playback only through this bus or the base `AudioHandler` API.
- **`PlaybackEngine`** (`services/playback_engine.dart`) — owns the `just_audio` `AudioPlayer` + `ConcatenatingAudioSource`, the `PlaybackPhase` state machine (`idle/loading/ready/playing/ended/error`), loudness normalization, and auto-advance detection. Knows nothing about `audio_service` queues or Hive.
- **`QueueManager`** (`services/queue_manager.dart`) — pure-Dart queue navigation: shuffle permutation, queue-loop wraparound, prev/next index computation. No dependency on `just_audio`.
- **`AutoplayOrchestrator`** (`services/autoplay_orchestrator.dart`) — watermark-driven (default 3 tracks remaining) predictive queue refill via `RecommendationService`, wired from `PlayerController`.
- **`PlayerController`** (`controllers/player_controller.dart`) — GetX controller, the UI's entry point to playback. Exposes individual `Rx<...>` fields (currentSong, buttonState, progressBarState, …) **and** a consolidated immutable `PlayerState` snapshot (`playerState` Rx). Handles session save/restore (`AppPrefs`), search history, like/unlike, sleep timer, and records every track start to `ListeningHistoryService`.

### URL resolution (`checkNGetUrl`)

Stream URLs resolve by priority: cached file → downloaded file (`DownloadsBox`, played as `file://` with NO network) → cached URL (`SongsUrlCache`, expiry checked via `expire=` param with a 30-min buffer) → fresh fetch. Fresh fetches run via `Isolate.run` (`services/background_task.dart` → `services/stream_service.dart`'s `StreamProvider`, using `youtube_explode_dart`) so the UI thread never blocks. Results are modeled by `HMStreamingData` (`models/hm_streaming_data.dart`), which holds low/high quality `Audio` and picks one from the user's `streamingQuality` pref.

### Personalization stack (on-device recommendations & mixes)

- **`ListeningHistoryService`** (`ListeningHistory` box) — per-`videoId` play counts + first/last-played timestamps. Richer than `PlayerController.searchHistory`; the signal behind the home mixes.
- **`TasteProfile`** (`services/taste_profile.dart`) — pure-Dart artist-affinity model built from liked songs (strong), play history (recency-weighted), and playlist tracks (noisy). Fully unit-tested; `TasteProfile.current()` wires the real on-device sources.
- **`RecommendationService`** re-ranks `YtMusicService.radio` candidates by the taste profile (`rerankByTaste`, demoting recently-played) without dropping any (discovery preserved).
- **`MixesService`** / **`PersonalizedMixesService`** — generate "Made For You" mixes on-device (per-artist mixes, Discovery, Repeat Rewind, Favorites, Throwback), each carrying its full track list inline so opening a mix needs no second request. Cached 24h, invalidated when listening changes; new users get a seeded Discovery Mix so home isn't empty.

### Offline downloads & playlist import (background jobs)

- **`DownloadService`** (`DownloadsBox`) + **`DownloadController`** — per-track offline downloads (bytes saved to the app data dir, surfaced to `checkNGetUrl` as `file://`). Controller holds reactive completed-list + in-flight progress.
- **`PlaylistDownloadService`** + **`PlaylistDownloadController`** — download a whole playlist in the background (per-song progress, completion badges on the Library tile).
- **`PlaylistImporter`** + **`ImportService`** + **`ImportController`** — import Spotify / Apple Music / YouTube playlists **entirely on-device**. Imports run in the background as `ImportJob`s rendered as placeholder tiles in the Library; failures stay on-screen as retry/dismiss tiles. Two distinct paths:
  - **Spotify / Apple** — scrape the platform's own public page for a server-rendered JSON blob (`__NEXT_DATA__` on Spotify's *embed* page, `serialized-server-data` on Apple's) to get (title, artist) per track, then **guess** the matching song via `YtMusicService.searchSongs`. Inherently fuzzy — a wrong match is invisible to the user.
  - **YouTube / YT Music** — no scraping: goes straight through `YtMusicService.playlist(listId)` (browse `VL<listId>`, following continuations, capped at `_maxPlaylistPages`). Tracks arrive with **real videoIds**, so `ImportedTrack.isResolved` is true and `ImportService` skips matching entirely — this path is exact, and its preview ETA drops to ~2s because no per-track search runs.

  Adding another source? Check first whether it server-renders its track list. Amazon Music does **not** — its playlist page is a client-side SPA shell (~11KB, no data blob, generic meta description even for crawlers), and Amazon publishes no public playlist API, so the embed-scrape technique cannot work there.

### Persistence (Hive boxes, opened in `main.dart`)

- `AppPrefs` — settings (streaming quality, loop/shuffle/queue-loop modes, loudness normalization, cache-songs toggle, search history, saved playback session)
- `SongsUrlCache` — cached resolved stream URLs keyed by video ID
- `LibraryBox` — liked songs + custom playlists (`LibraryService`, `LibraryTrack`/`LocalPlaylist`)
- `CacheBox` — generic TTL'd JSON cache (`CacheService`): home data (2h), playlist details (24h), album details (24h)
- `DownloadsBox` — downloaded track metadata + file paths
- `ListeningHistory` — per-`videoId` play counts/timestamps

Hive is initialized from `appDataDirectory()` (`services/app_paths.dart`) rather than `initFlutter()`, because `getApplicationDocumentsDirectory()` shells out to `xdg-user-dir` on desktop and throws. Downloaded audio lives under the same base dir.

### UI layer

GetX throughout — controllers registered via `Get.put`/`Get.find` in `main.dart`; reactive state via `Rx`/`.obs`/`Obx`. `GetMaterialApp` (`YTPlayerApp` in `main.dart`) is the root, with `RootShell` (`ui/shell/root_shell.dart`) as `home`.

- **`RootShell`** — all tabs stay mounted in an `IndexedStack` (state preserved) but only the active screen paints (compositing two blurred screens at once was the #1 jank source); the floating mini-player + nav dock layer above. Screens add `AppSpacing.bottomDock` padding so nothing hides behind the dock.
- **Responsive shell** (`ui/shell/responsive.dart`) — desktop sidebar shell activates at width ≥ `kDesktopBreakpoint` (900px); below it the mobile shell renders unchanged. `gridColumns(width)` scales content grids.
- **`DynamicColorController`** (`ui/theme/dynamic_color_controller.dart`) — runs `palette_generator` on the current track's (already-cached) artwork to derive a per-track `accent`/`base` color; widgets `Obx` on these to tint backgrounds/glows/controls.
- **`GlassContainer`** & friends (`ui/theme/glass.dart`) — the backdrop-blur/border/fill primitives every floating surface is built on.
- **`LyricsController`** (`controllers/lyrics_controller.dart`) — fetches/syncs lyrics (via `LyricsService`/lrclib), wired off `PlayerController.currentSong` in `main.dart`.
- **`AppShortcuts`** (`ui/shell/app_shortcuts.dart`) — the single source of truth for keyboard shortcuts, mounted through `GetMaterialApp`'s **`builder`** so it sits **above the root Navigator**. This placement is load-bearing: shortcuts previously lived in `DesktopShell`, which is *below* the Navigator, so they never fired on pushed routes (Now Playing, Album/Mix detail). Two rules when touching this file:
  - Media bindings must stay wrapped in `_GuardedAction`, whose `isEnabled` returns false while a text field has focus. A disabled action resolves to `KeyEventResult.ignored`, letting the key bubble on to Flutter's text-editing handlers — that's what keeps `Space` typing a space in Search.
  - `_isEditableFocused()` checks the focus context and its **ancestors only**. Never re-add a descendant walk: `FocusableActionDetector`/high-level focus nodes sit above the whole app, and `SearchScreen`'s `TextField` is permanently mounted in `RootShell`'s `IndexedStack`, so a descendant search always finds an `EditableText` and silently disables every shortcut.
- **`ShellNav`** (`ui/shell/root_shell.dart`) — a static hook (`goToTab`) letting `AppShortcuts` switch tabs; it's mounted above the Navigator and so can't reach `RootShell`'s State. Set in `initState`, cleared in `dispose`.
- **`SearchUiController`** owns the search `TextEditingController` + `FocusNode` (not `SearchScreen.build`, where they'd be recreated every rebuild and drop typed text). The `FocusNode` is what `Ctrl+F` targets.

### Cloud sync (optional, opt-in)

`services/cloud/` — entirely optional; when `SupabaseConfig` isn't configured every method is a safe no-op and the app runs fully offline/account-free.

- **`AuthService`** — Supabase Auth + **native** Google sign-in (`google_sign_in` 7.x `authenticate()`), Android/iOS only; desktop is unsupported and throws. Initialized *after* the first frame in `main.dart` so `Supabase.initialize()` never delays cold start — hence `SyncService` is registered only in that callback, and UI must guard on `Get.isRegistered<SyncService>()`.
- **`SyncService`** — GetX controller; Hive `LibraryBox` stays the source of truth. Sign-in pulls remote and **unions** into local, then pushes the merge; local mutations trigger a debounced full-state push.
- **Gotcha:** Android reports an *unregistered SHA-1* (a signing/OAuth mismatch) using the same `canceled` code as a genuine user dismissal, so failures can look like "the button does nothing". Every `GoogleSignInException` is now `debugPrint`ed with `[auth]` — check logcat before assuming the code is wrong. Release builds currently sign with the **debug keystore** (`android/app/build.gradle.kts`), so regenerating `~/.android/debug.keystore` breaks sign-in until the new SHA-1 is added to the Android OAuth client.

### Platform integration

- **`ThumbUtil`** (`services/thumb_util.dart`) — rewrites YouTube/googleusercontent thumbnail URLs to the right size tier (`micro`/`tile`/`card`/`art`) for where they're displayed. Always route thumbnails through this.
- **`BatteryOptimization`** (`services/battery_optimization.dart`) — Android-only `MethodChannel` (`com.saragama/battery`, backed by `MainActivity.kt`) that prompts once to exempt the app from Doze so background playback survives screen-off.
- **Desktop audio/MPRIS** — `just_audio` has no native Linux/Windows backend, so `main.dart` initializes `just_audio_media_kit` (libmpv) on **both** Linux and Windows before `AudioService.init()`. media_kit hardcodes libmpv `cache-on-disk=yes`; `ensureMpvCacheDir()` pre-creates `~/.cache/mpv` (libmpv won't, and a missing dir breaks seek/skip/auto-advance). A local patched `just_audio_media_kit` override may exist in `pubspec.yaml`.
  - `audio_service_mpris` (media keys / system media widget) is **Linux-only** — MPRIS is D-Bus. Windows has **no** System Media Transport Controls integration yet, so hardware media keys and the Windows volume-flyout media overlay do nothing there; `smtc_windows` would be the way in. In-app keyboard shortcuts (`AppShortcuts`) are the current Windows substitute, but they only work while the app has focus.
