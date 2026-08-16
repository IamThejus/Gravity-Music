// services/audio_effects.dart
// Platform seam for audio DSP. Two backends behind one API:
//
//   Desktop (Linux/Windows) — playback runs through media_kit/libmpv, whose
//   `af` property takes an ffmpeg filter graph. Our 10 ISO bands map 1:1 onto
//   ffmpeg `equalizer` nodes, and mono onto a `pan` downmix; because `af` is
//   ONE property, every effect composes into one graph (buildFilterChain in
//   equalizer.dart) and [apply] takes them all together.
//
//   Android — playback runs through just_audio/ExoPlayer, which exposes the
//   platform's android.media.audiofx.Equalizer as an AndroidEqualizer inside
//   an AudioPipeline. The pipeline must be handed to the AudioPlayer at
//   CONSTRUCTION time, so PlaybackEngine creates the effect and hands it here
//   via [attachAndroidEqualizer]; this class never builds one itself. That
//   equalizer's bands are chosen by the DEVICE (commonly five, at frequencies
//   of its own choosing), so the user's 10-band curve is resampled onto them
//   with gainAtFrequency rather than applied index by index. There is no mono
//   equivalent — just_audio's pipeline offers only LoudnessEnhancer and
//   Equalizer, and ExoPlayer's channel-mapping processor isn't reachable from
//   Dart — so Android's own system-wide Accessibility setting owns mono there
//   (SystemSettings.openAccessibility).
//
// iOS/macOS have no implementation: main.dart brings up neither media_kit nor
// (on those platforms) an AudioPipeline, so both isEqualizerSupported and
// isMonoSupported are false and the UI hides the controls rather than showing
// dead ones.
//
// Everything in this file is best-effort by design: an effects failure must
// degrade to "no effect" and must never throw into the playback path.

import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/mediakit_player.dart';

import '../util/log.dart';
import 'equalizer.dart';

class AudioEffects {
  // macOS is deliberately excluded from the desktop path even though media_kit
  // itself supports it: main.dart only initialises JustAudioMediaKit/
  // AudioServiceMpris for Linux/Windows, so on macOS there is no media_kit
  // player at all and MediaKitPlayer.setActivePlayerProperty would talk to a
  // backend that was never brought up.
  static final bool _isDesktop = Platform.isLinux || Platform.isWindows;
  static final bool _isAndroid = Platform.isAndroid;

  /// Whether an equalizer can actually do anything on this platform. The UI
  /// uses this to hide EQ controls rather than show dead ones.
  static bool get isEqualizerSupported => _isDesktop || _isAndroid;

  /// Whether mono downmixing can be applied in-app. Desktop only: it rides
  /// mpv's filter graph, and just_audio's Android pipeline exposes no
  /// channel-mixing effect (Android instead offers mono system-wide, under
  /// Accessibility — see SystemSettings.openAccessibility).
  static bool get isMonoSupported => _isDesktop;

  /// The pipeline effect owned by PlaybackEngine's AudioPlayer, on Android.
  /// Null on every other platform and until the engine has booted.
  static AndroidEqualizer? _androidEqualizer;

  /// Register the AudioPipeline's equalizer. Called once by
  /// PlaybackEngine.init(), which is the only place that can create it (the
  /// pipeline is a constructor argument of AudioPlayer).
  static void attachAndroidEqualizer(AndroidEqualizer equalizer) {
    _androidEqualizer = equalizer;
  }

  /// Bumped by every [apply] call so a slow Android apply can detect that a
  /// newer one has superseded it mid-flight and bail out instead of writing
  /// stale gains over fresh ones.
  static int _generation = 0;

  /// Push the state of EVERY effect to the backend in one go: [bands] (one
  /// gain in dB per [kEqFrequencies] entry), whether the equalizer is
  /// bypassed, and whether to downmix to mono.
  ///
  /// Deliberately not one method per effect. On desktop all of this becomes a
  /// single mpv `af` value, so a per-effect API would need each call to know
  /// the other's current state or it would clobber it; taking the full state
  /// every time makes that impossible to get wrong.
  ///
  /// Silently does nothing on unsupported platforms. May also be a no-op if
  /// the underlying platform player hasn't been created yet — desktop
  /// constructs it lazily on the first loadCurrent(), and Android's effect
  /// parameters aren't readable until the player activates. Callers are
  /// responsible for re-applying once a player is known to exist; see the two
  /// `ever(...)` hooks registered in main.dart.
  static Future<void> apply({
    required List<double> bands,
    required bool equalizerEnabled,
    required bool mono,
  }) async {
    final generation = ++_generation;
    try {
      if (_isDesktop) {
        // One write, every effect: `af` has a single writer by design.
        await MediaKitPlayer.setActivePlayerProperty(
          'af',
          buildFilterChain(
            bands: bands,
            equalizerEnabled: equalizerEnabled,
            mono: mono,
          ),
        );
      } else if (_isAndroid) {
        // `mono` is unused here: Android has no in-app downmix, and the UI
        // never lets it become true there (isMonoSupported is false).
        await _applyAndroid(bands, equalizerEnabled, generation);
      }
    } catch (e) {
      // Logged, not silently swallowed — but never rethrown: an effects
      // failure must degrade to "no effect", never break playback.
      logD('eq', 'applying audio effects failed: $e');
    }
  }

  static Future<void> _applyAndroid(
    List<double> bands,
    bool enabled,
    int generation,
  ) async {
    final equalizer = _androidEqualizer;
    if (equalizer == null) return;

    await equalizer.setEnabled(enabled);
    // While bypassed the gains are inaudible, and reading `parameters` below
    // would block for nothing on a cold start where the user has the EQ off.
    if (!enabled) return;

    // just_audio only completes `parameters` when the effect activates, i.e.
    // when the platform player exists — on a cold start, not until the first
    // track loads. Without a timeout every pre-playback apply would park a
    // future here forever, and they would all wake at once on the first play
    // and race to write stale gains. Time out instead and let the reapply()
    // hooks in main.dart re-run this once playback is actually live.
    final AndroidEqualizerParameters params;
    try {
      params = await equalizer.parameters.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      logD('eq', 'android equalizer not active yet; deferring');
      return;
    }
    if (generation != _generation) return; // superseded while awaiting

    for (final band in params.bands) {
      // Clamp to what the DEVICE supports, not to our own ±12 dB: the two
      // ranges need not match (Android commonly reports ±15 dB, but nothing
      // guarantees it), and an out-of-range level is rejected by the platform.
      final gain = gainAtFrequency(bands, band.centerFrequency)
          .clamp(params.minDecibels, params.maxDecibels)
          .toDouble();
      await band.setGain(gain);
      if (generation != _generation) return;
    }
  }
}
