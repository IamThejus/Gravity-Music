// services/audio_effects.dart
// Platform seam for audio DSP. Desktop (Linux/Windows/macOS) runs playback
// through media_kit/libmpv, whose `af` property accepts an ffmpeg filter graph
// — that is how the equalizer is applied. Android/iOS use just_audio's own
// backend, which has no equivalent here yet, so this is a no-op there.
//
// Everything in this file is best-effort by design: an effects failure must
// degrade to "no effect" and must never throw into the playback path.

import 'dart:io';

import 'package:just_audio_media_kit/mediakit_player.dart';

import '../util/log.dart';

class AudioEffects {
  static final bool _isDesktop =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// Whether an equalizer can actually do anything on this platform. The UI
  /// uses this to hide EQ controls rather than show dead ones.
  static bool get isEqualizerSupported => _isDesktop;

  /// Apply [chain] as mpv's `af` value. An empty string removes all filters.
  ///
  /// Silently does nothing off desktop, or when no player exists yet (the
  /// caller re-applies on track change, by which point one does).
  static Future<void> applyEqualizer(String chain) async {
    if (!_isDesktop) return;
    try {
      await MediaKitPlayer.setActivePlayerProperty('af', chain);
    } catch (e) {
      // Logged, not silently swallowed — but never rethrown: an effects
      // failure must degrade to "no EQ", never break playback.
      logD('eq', 'applyEqualizer failed: $e');
    }
  }
}
