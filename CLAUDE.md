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

The app once used a hosted "SaraGama" API (a Render server wrapping `ytmusicapi`). That is **gone** — everything now runs on the device. The pivot point is **`YtMusicService`** (`services/yt_music_service.dart`), a client that calls music.youtube.com's internal `youtubei` endpoints directly (search with the "Songs" filter, and `next`/radio for queues). It returns clean Art Tracks (real titles/artists/album + square `googleusercontent` art). Its response is a deeply-nested `…Renderer` tree parsed defensively, so one shape change doesn't discard the whole result. **`SearchService`, `RecommendationService`, `MixesService`, and `ImportService` are all thin layers over `YtMusicService`** — when "up next" or search behaves oddly, suspect the youtubei parsing here.

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
- **`PlaylistImporter`** + **`ImportService`** + **`ImportController`** — import Spotify / Apple Music playlists **entirely on-device**: scrape the platform's own public embed pages for (title, artist) per track, then match each to YouTube Music via `YtMusicService`. Imports run in the background as `ImportJob`s rendered as placeholder tiles in the Library; failures stay on-screen as retry/dismiss tiles.

### Persistence (Hive boxes, opened in `main.dart`)

- `AppPrefs` — settings (streaming quality, loop/shuffle/queue-loop modes, loudness normalization, cache-songs toggle, search history, saved playback session)
- `SongsUrlCache` — cached resolved stream URLs keyed by video ID
- `LibraryBox` — liked songs + custom playlists (`LibraryService`, `LibraryTrack`/`LocalPlaylist`)
- `CacheBox` — generic TTL'd JSON cache (`CacheService`): home data (2h), playlist details (24h)
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

### Platform integration

- **`ThumbUtil`** (`services/thumb_util.dart`) — rewrites YouTube/googleusercontent thumbnail URLs to the right size tier (`micro`/`tile`/`card`/`art`) for where they're displayed. Always route thumbnails through this.
- **`BatteryOptimization`** (`services/battery_optimization.dart`) — Android-only `MethodChannel` (`com.saragama/battery`, backed by `MainActivity.kt`) that prompts once to exempt the app from Doze so background playback survives screen-off.
- **Desktop audio/MPRIS** — `just_audio` has no native Linux/Windows backend, so `main.dart` initializes `just_audio_media_kit` (libmpv) and `audio_service_mpris` (media keys / system media widget) before `AudioService.init()`. media_kit hardcodes libmpv `cache-on-disk=yes`; `ensureMpvCacheDir()` pre-creates `~/.cache/mpv` (libmpv won't, and a missing dir breaks seek/skip/auto-advance). A local patched `just_audio_media_kit` override may exist in `pubspec.yaml`.
