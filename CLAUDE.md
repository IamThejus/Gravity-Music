# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Gravity Music** (package name `saragama`) — a Flutter Android music player that streams audio from YouTube via `youtube_explode_dart`. Architecture and playback logic are a Flutter port of **HarmonyMusic**; several files explicitly say "mirrors HarmonyMusic's X" — when in doubt about *why* something is structured a certain way, that's the reference implementation it was ported from.

## Commands

- `flutter pub get` — install dependencies
- `flutter run` — run on a connected device/emulator (Android is the primary target; iOS/desktop/web folders exist but are unconfirmed/untested)
- `flutter analyze` — static analysis (uses `flutter_lints`, see `analysis_options.yaml`)
- `flutter test` — run tests (no test suite currently exists; `queue_manager.dart` and similar pure-Dart services are explicitly designed to be unit-testable without booting the audio handler)
- `flutter build apk` — build Android release APK

## Current state — IMPORTANT

`lib/main.dart` imports `ui/player_screen.dart`, which **does not exist yet**. There is currently no UI screen layer (`lib/ui/` only contains `app_theme.dart`). The app will not compile until a `PlayerScreen` (and likely other screens) are created. The `references/` directory contains HTML/CSS mockups (Tailwind) and a design spec intended to guide building these screens:

- `references/gravity_music/DESIGN.md` — full design system spec (colors, typography, spacing, component styles — "Cinematic Dark" / glassmorphism aesthetic, obsidian black OLED palette, 30px backdrop blurs, floating "suspended" layout with no element touching screen edges)
- `references/home/`, `references/library/`, `references/now_playing/`, `references/search/` — each has `code.html` (Tailwind mockup) and `screen.png` (visual reference) for that screen

When building UI, follow the design tokens in `DESIGN.md` and the existing `lib/ui/app_theme.dart` (`AppColors`, `AppText`) — note `app_theme.dart`'s current palette (pure black `#000000`, red accent `#FF3B30`) predates `DESIGN.md` and may need reconciling with the spec's lighter "obsidian" palette and white accent.

## Architecture

The playback stack is split into focused layers, each with a single responsibility — read the file-header comments in `lib/services/` before modifying, they document *why* the split exists:

- **`MyAudioHandler`** (`services/audio_handler.dart`) — the `audio_service`-facing layer (notification/lockscreen contract). Owns `queue`/`mediaItem`/`playbackState` subjects and the **`customAction` command bus** — all complex operations (`playByIndex`, `setSourceNPlay`, `playAllFrom`, `playShuffled`, `restoreSession`, `reorderQueue`, `addPlayNextItem`, `clearQueue`, etc.) are dispatched through `customAction(name, extras)` rather than dedicated methods. UI talks to playback only through this bus or the base `AudioHandler` API.
- **`PlaybackEngine`** (`services/playback_engine.dart`) — owns the `just_audio` `AudioPlayer` + `ConcatenatingAudioSource`, the `PlaybackPhase` state machine (`idle/loading/ready/playing/ended/error`), loudness normalization, and auto-advance detection. Knows nothing about `audio_service` queues or Hive.
- **`QueueManager`** (`services/queue_manager.dart`) — pure-Dart queue navigation: shuffle permutation, queue-loop wraparound, prev/next index computation. No dependency on `just_audio`.
- **`AutoplayOrchestrator`** (`services/autoplay_orchestrator.dart`) — watermark-driven (default 3 tracks remaining) predictive queue refill via `RecommendationService`, wired from `PlayerController`.
- **`PlayerController`** (`controllers/player_controller.dart`) — GetX controller, the UI's entry point to playback. Exposes both individual `Rx<...>` fields (currentSong, buttonState, progressBarState, etc.) and a consolidated immutable `PlayerState` snapshot (`playerState` Rx) updated in parallel. Also handles session save/restore (Hive `AppPrefs`), search history, like/unlike, sleep timer.
- **`LyricsController`** (`controllers/lyrics_controller.dart`) — fetches/syncs lyrics (via `LyricsService`/lrclib) keyed off `PlayerController.currentSong` changes (wired in `main.dart`).

### URL resolution (`checkNGetUrl`)

Stream URLs are resolved with priority: cached file → downloaded file → cached URL (Hive `SongsUrlCache`, checked for expiry via `expire=` param with a 30-min buffer) → fresh fetch. Fresh fetches run via `Isolate.run` (`services/background_task.dart` → `services/stream_service.dart`'s `StreamProvider`, using `youtube_explode_dart`) so the UI thread is never blocked. Results are modeled by `HMStreamingData` (`models/hm_streaming_data.dart`), which holds both low/high quality `Audio` and picks one based on the user's `streamingQuality` Hive pref.

### Persistence (Hive boxes, opened in `main.dart`)

- `AppPrefs` — settings (streaming quality, loop/shuffle/queue-loop modes, loudness normalization, cache-songs toggle, search history, saved playback session)
- `SongsUrlCache` — cached resolved stream URLs keyed by video ID
- `LibraryBox` — liked songs + custom playlists (`LibraryService`, `LibraryTrack`/`LocalPlaylist`)
- `CacheBox` — generic TTL'd JSON cache (`CacheService`): home data (2h TTL), playlist details (24h TTL)

### Other services

- `ThumbUtil` (`services/thumb_util.dart`) — rewrites YouTube CDN thumbnail URLs to request the right size tier (`micro`/`tile`/`card`/`art`) for where they're displayed — always use this rather than raw thumbnail URLs.
- `BatteryOptimization` (`services/battery_optimization.dart`) — Android-only `MethodChannel` (`com.saragama/battery`, backed by `MainActivity.kt`) that prompts once to exempt the app from Doze so background playback survives screen-off.
- `SearchService` / `RecommendationService` — HTTP-based search and "up next" recommendations, both returning thumbnail URLs that should go through `ThumbUtil`.

## State management

GetX (`get` package) throughout — controllers registered via `Get.put`/`Get.find` in `main.dart`, reactive state via `Rx`/`.obs`. `GetMaterialApp` is the root widget (`YTPlayerApp` in `main.dart`).
