// main.dart
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'services/app_paths.dart';
import 'controllers/download_controller.dart';
import 'controllers/import_controller.dart';
import 'controllers/lyrics_controller.dart';
import 'controllers/player_controller.dart';
import 'controllers/playlist_download_controller.dart';
import 'services/audio_handler.dart';
import 'services/battery_optimization.dart';
import 'ui/app_theme.dart';
import 'ui/shell/root_shell.dart';
import 'ui/theme/dynamic_color_controller.dart';
import 'ui/theme/motion.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Desktop playback backend ──────────────────────────────────────────────
  // just_audio has no native Linux/Windows implementation; media_kit (libmpv)
  // provides one. Self-guards by platform (no-op on Android/iOS), but the
  // explicit guard keeps intent clear. Must run before any AudioPlayer is
  // constructed (i.e. before initAudioService()).
  if (Platform.isLinux || Platform.isWindows) {
    // media_kit runs libmpv with `cache-on-disk=yes` hardcoded, whose on-disk
    // cache lives in $XDG_CACHE_HOME/mpv (~/.cache/mpv). The embedded libmpv
    // does NOT create that directory itself (unlike the mpv CLI), so when it's
    // missing mpv logs "Failed to create file cache" and the subsequent
    // seek(0) fails — which breaks skip/auto-advance/loop. Pre-create it.
    ensureMpvCacheDir();
    JustAudioMediaKit.ensureInitialized();
  }

  // ── Linux MPRIS system integration ────────────────────────────────────────
  // Registers audio_service's Linux platform (media keys, lock screen, system
  // media widget). Synchronous, and MUST be called before AudioService.init().
  // canControl must be true or the per-action flags are forced false.
  if (Platform.isLinux) {
    AudioServiceMpris.init(
      dBusName: 'gravity_music',
      identity: 'Gravity Music',
      // Links MPRIS to the installed .desktop entry so system media widgets
      // show the app icon/name. Matches the GTK application-id and the
      // installed desktop file basename (com.example.saraharmony.desktop).
      desktopEntry: 'com.example.saraharmony',
      canControl: true,
      canPlay: true,
      canPause: true,
      canGoNext: true,
      canGoPrevious: true,
    );
  }

  // ── Hive init (same boxes as HarmonyMusic) ────────────────────────────────
  // Hive.initFlutter() resolves its path via getApplicationDocumentsDirectory(),
  // which throws on Linux desktop (xdg-user-dir). Init explicitly from the
  // platform-correct base dir instead — on mobile this is the documents dir,
  // identical to initFlutter()'s behaviour.
  Hive.init((await appDataDirectory()).path);
  await Hive.openBox('AppPrefs');
  await Hive.openBox('SongsUrlCache');
  await Hive.openBox('LibraryBox');
  await Hive.openBox('CacheBox');
  await Hive.openBox('DownloadsBox');

  // ── Register audio handler (same as HarmonyMusic) ─────────────────────────
  final audioHandler = await initAudioService();

  // ── Register PlayerController as GetX dependency ──────────────────────────
  Get.put(PlayerController(audioHandler: audioHandler));
  final lyricsController = Get.put(LyricsController());

  // Drives the artwork → accent/base color theming used across the UI.
  Get.put(DynamicColorController());

  // Offline downloads (file persistence + reactive progress/list).
  Get.put(DownloadController());

  // Background playlist import (non-blocking; renders placeholder tiles in
  // the Library while imports resolve).
  Get.put(ImportController());

  // Background playlist offline downloads (separate from the per-track
  // Downloads tab; drives the tile download badges).
  Get.put(PlaylistDownloadController());

// Listen to song changes and auto-fetch lyrics
ever(Get.find<PlayerController>().currentSong, (song) {
  if (song != null) {
    lyricsController.fetchLyrics(
      trackId:      song.id,
      title:        song.title,
      artist:       song.artist ?? '',
      thumbnailUrl: song.artUri?.toString(),
    );
  }
});

  runApp(const YTPlayerApp());

  // One-time prompt (Android) to exempt the app from battery optimization,
  // so Doze doesn't freeze the process / cut network and stall background
  // playback while the screen is off. Runs after the first frame so the
  // system dialog appears over a rendered UI.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    BatteryOptimization.maybePrompt();
  });
}

class YTPlayerApp extends StatelessWidget {
  const YTPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.canvas,
      brightness: Brightness.dark,
    ).copyWith(surface: AppColors.canvas);

    return GetMaterialApp(
      title: 'Gravity Music',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: AppColors.canvas,
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        sliderTheme: const SliderThemeData(
          trackShape: RoundedRectSliderTrackShape(),
        ),
        // Replace the stock platform (Android zoom) page transition with a
        // calm fade-through so all navigation shares one continuous language.
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: FadeThroughPageTransitionsBuilder(),
            TargetPlatform.iOS: FadeThroughPageTransitionsBuilder(),
            TargetPlatform.fuchsia: FadeThroughPageTransitionsBuilder(),
            TargetPlatform.linux: FadeThroughPageTransitionsBuilder(),
            TargetPlatform.macOS: FadeThroughPageTransitionsBuilder(),
            TargetPlatform.windows: FadeThroughPageTransitionsBuilder(),
          },
        ),
        useMaterial3: true,
      ),
      home: const RootShell(),
    );
  }
}