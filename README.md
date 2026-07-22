# Gravity Music

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20Linux-blue)](#download)
[![Built with Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B?logo=flutter)](https://flutter.dev)

A free and open-source music player with dynamic album-driven visuals, a floating glassmorphism UI, personalized on-device discovery, and playlists — built with Flutter and streaming from YouTube. Runs on Android (primary target) and Linux/Windows desktop.

**No ads. No trackers. No accounts. No paywalls.** Every feature is available to everyone, forever — there is no paid tier and nothing is held back. Personalization (mixes, recommendations, taste profile) is computed entirely **on your device**; there is no backend server collecting your listening data. Cloud sync is optional and opt-in. The only thing the app ever reports is an anonymous, aggregate usage heartbeat — a random ID, platform, and app version, nothing more — fully documented in [Privacy & Anonymous Usage Stats](#privacy--anonymous-usage-stats).


<img src="media/banner.png" alt="Gravity Music Banner" />

## Screenshots

<table>
  <tr>
    <td><img src="media/home_screen.jpeg" width="250"/></td>
    <td><img src="media/search_screen.jpeg" width="250"/></td>
    <td><img src="media/library_screen.jpeg" width="250"/></td>
  </tr>
  <tr>
    <td align="center"><b>Home</b></td>
    <td align="center"><b>Search</b></td>
    <td align="center"><b>Library</b></td>
  </tr>
  <tr>
    <td><img src="media/now_playing.jpeg" width="250"/></td>
    <td><img src="media/playlist_screen.jpeg" width="250"/></td>
    <td><img src="media/queue_screen.jpeg" width="250"/></td>
  </tr>
  <tr>
    <td align="center"><b>Now Playing</b></td>
    <td align="center"><b>Playlist</b></td>
    <td align="center"><b>Queue</b></td>
  </tr>
</table>

### Android Auto

<table>
  <tr>
    <td><img src="media/andriod_auto(in car).png" width="400"/></td>
    <td><img src="media/andrio_auto(Playlists).png" width="250"/></td>
    <td><img src="media/andriod_auto(Map view).png" width="250"/></td>
  </tr>
  <tr>
    <td align="center"><b>In-car display</b></td>
    <td align="center"><b>Browse Playlists</b></td>
    <td align="center"><b>Map View</b></td>
  </tr>
</table>

### Desktop (Linux)

<table>
  <tr>
    <td><img src="media/Gnome(Manjro)(Wayland) App.png" width="500"/></td>
    <td><img src="media/Gnome(Manjro)(Wayland) PlayBar.png" width="500"/></td>
  </tr>
  <tr>
    <td align="center"><b>App</b></td>
    <td align="center"><b>System Media Controls (MPRIS)</b></td>
  </tr>
</table>

## Download

Grab the latest build for your platform from the [**Releases**](https://github.com/IamThejus/Gravity-Music/releases/latest) page:

| Platform | Package |
|----------|---------|
| **Android** | `.apk` (sideload) |
| **Windows** | `.exe` installer (also available as `.msix`) |
| **Linux** | `.deb` / `.rpm` |

> Builds are signed with a debug / self-signed certificate (not the Play Store or Microsoft Store), so your OS shows a first-run warning — this is expected for a sideloaded, open-source app. On **Windows** choose **More info → Run anyway**; on **Android** allow installs from your browser or file manager.

## Features

- **Cinematic Dark UI** — obsidian glassmorphism design with floating navigation, a floating mini-player, and blurred translucent surfaces
- **Dynamic theming** — accent and background colors are extracted from the current track's artwork
- **Home** — recently played, personalized "Mixes" generated on-device from your listening history (Artist Mixes, Discovery, Repeat Rewind, Throwbacks, Favorites), and your playlists
- **Search** — find songs, artists, and genres on YouTube Music, plus **album results**: open an album for its full tracklist, artwork and metadata, then play or shuffle it like any playlist
- **Library** — liked songs, custom playlists, and offline downloads
- **Offline playlists** — download an entire playlist for offline listening in the background, with progress and completion badges on the playlist tile
- **Playlist import** — import playlists from **YouTube / YouTube Music, Spotify, or Apple Music** links, running in the background while you keep listening. YouTube links import *exactly* (real video IDs, nothing guessed); Spotify and Apple tracks are matched by search
- **Now Playing** — full-screen player with synced lyrics, queue management, shuffle/loop, sleep timer, and streaming quality toggle
- **Background playback** — lock-screen and notification controls with high-resolution artwork, loudness normalization, and session restore across app restarts
- **Android Auto** — browse and play your playlists from the car
- **Desktop experience** — sidebar layout, a persistent now-playing bar with a volume slider, and full keyboard shortcuts (see below)
- **Offline-friendly caching** — resolved stream URLs, song downloads, home/playlist/album data are cached locally
- **Cloud sync (optional)** — sign in with Google to back up and sync your liked songs and playlists across devices via Supabase; the app remains fully offline and account-free unless you opt in

## Privacy & Anonymous Usage Stats

Gravity Music collects **no personal data**. There are no analytics SDKs, no trackers, and no account requirement — personalization runs entirely on your device.

To power the two public counters on the website (🎧 *listening now* / 📱 *installations*), the app sends a tiny anonymous **heartbeat** to a self-hosted [Cloudflare Worker](https://workers.cloudflare.com/) — **only while music is actually playing**, once per minute. Nothing is sent on app open, browsing, searching, or while paused.

Each heartbeat contains exactly three fields:

| Field | Example | Why |
|---|---|---|
| `installation_id` | random UUID v4 | counts each install once — generated on-device from secure random, tied to nothing |
| `platform` | `android` | per-platform counts |
| `app_version` | `1.4.0` | version adoption |

**What is never collected:** songs, artists, playlists, listening or search history, user identity, emails, device identifiers (Android ID, IMEI, MAC address, advertising ID, serial number), or location. IP addresses are not persisted. The random ID cannot be traced back to you or your device — it isn't derived from anything — and clearing the app's data simply generates a new one.

The backend stores only: the anonymous ID, platform, app version, and first-seen / last-heartbeat timestamps. The entire client implementation is ~150 lines of open, auditable code: [`lib/services/heartbeat_service.dart`](lib/services/heartbeat_service.dart).

## Keyboard Shortcuts (desktop)

Shortcuts work on every screen. They're automatically disabled while you're typing in the search field, so `Space` still types a space.

| Key | Action |
|-----|--------|
| `Space` | Play / pause |
| `←` / `→` | Seek backward / forward 10s |
| `Ctrl` + `←` / `→` | Previous / next track |
| `↑` / `↓` | Volume up / down |
| `M` | Mute toggle |
| `L` | Like current track |
| `S` / `R` | Shuffle / repeat |
| `Ctrl` + `F` | Jump to search |
| `Esc` | Close lyrics, or go back |

## Tech Stack

- [Flutter](https://flutter.dev) (Dart) — Android primary; Linux/Windows desktop via media_kit
- [GetX](https://pub.dev/packages/get) — state management
- [audio_service](https://pub.dev/packages/audio_service) + [just_audio](https://pub.dev/packages/just_audio) — background playback, lock-screen/notification integration
- [just_audio_media_kit](https://pub.dev/packages/just_audio_media_kit) + [audio_service_mpris](https://pub.dev/packages/audio_service_mpris) — Linux/Windows audio backend and MPRIS system media integration
- [youtube_explode_dart](https://pub.dev/packages/youtube_explode_dart) — YouTube stream resolution
- YouTube Music `youtubei` API (on-device) — search, recommendations, radio/mixes with no external server
- [Hive](https://pub.dev/packages/hive) — local persistence (settings, cache, library, downloads, listening history)
- [palette_generator](https://pub.dev/packages/palette_generator) — dynamic color extraction from album art
- [lrclib.net](https://lrclib.net) — synced lyrics
- [supabase_flutter](https://pub.dev/packages/supabase_flutter) + [google_sign_in](https://pub.dev/packages/google_sign_in) — optional cloud sync and Google authentication
- [Cloudflare Workers](https://workers.cloudflare.com) — anonymous listener/installation counters for the website (random ID + platform + version only; see [Privacy & Anonymous Usage Stats](#privacy--anonymous-usage-stats))

## Getting Started

```bash
flutter pub get           # install dependencies
flutter run               # run on a connected Android device/emulator
flutter run -d linux      # run on Linux desktop
flutter run -d windows    # run on Windows desktop
flutter analyze           # static analysis
flutter test              # run the test suite
flutter build apk         # build a release APK
flutter build windows     # build the Windows release runner
```

## Architecture

**All backend logic runs on-device** — search, recommendations, and mixes call YouTube Music's internal `youtubei` API directly; no external server is involved.

The playback stack is split into focused layers:

- **`MyAudioHandler`** — `audio_service`-facing layer (notification/lock-screen/MPRIS contract) and command bus for all playback operations
- **`PlaybackEngine`** — owns the `just_audio` player, playback state machine, loudness normalization, auto-advance
- **`QueueManager`** — pure-Dart queue navigation (shuffle, loop, prev/next)
- **`AutoplayOrchestrator`** — predictive queue refill via taste-profile-reranked recommendations
- **`PlayerController`** — GetX controller exposing playback state to the UI, session save/restore, likes, search history, sleep timer; records every play to `ListeningHistoryService`
- **`LyricsController`** — fetches and syncs lyrics from lrclib.net

Personalization:
- **`ListeningHistoryService`** — per-track play counts and timestamps powering the home mixes
- **`TasteProfile`** — on-device artist-affinity model (liked songs + play history) used to re-rank "up next" candidates
- **`MixesService`** / **`PersonalizedMixesService`** — generate "Made For You" mixes entirely on-device; new users get a seeded Discovery Mix so home is never empty

Stream URLs resolve cache-first: downloaded file (`file://`) → cached URL → fresh fetch via an isolate, modeled by `HMStreamingData`.

## Contributing

Contributions are welcome — issues, feature ideas, and pull requests all help.

1. Fork the repo and create a branch off `main`
2. Run `flutter analyze` and `flutter test` before opening a PR
3. Match the surrounding code style; most files carry a header comment explaining *why* they're structured the way they are — worth reading before changing one

If you're unsure whether an idea fits, open an issue first and let's talk it through. Bug reports are just as valuable as code: please include your platform, app version, and steps to reproduce.

## License

The **source code** is released under the [MIT License](LICENSE) — free to use, modify, and redistribute. If you build something on top of it, a link back is appreciated but not required.

Note that the MIT license applies to this repository's code, not to the music it plays. The app itself is distributed free of charge and is **not intended for monetization or resale** — see the disclaimer below.

## Disclaimer

This project is built for learning and exploration, and is not affiliated with or endorsed by YouTube, Google, Spotify, or Apple.

Gravity Music streams audio from **YouTube** using YouTube's internal APIs and [`youtube_explode_dart`](https://pub.dev/packages/youtube_explode_dart). It does not host, store, or redistribute any audio or video content — all media is served directly from YouTube's CDN in real time, the same way a browser would.

Use of this app may be subject to [YouTube's Terms of Service](https://www.youtube.com/t/terms). The author takes no responsibility for any ToS implications, misuse, or legal issues arising from the use of this software. **Use at your own risk.**
