// services/audio_effects.dart
// Platform seam for audio DSP. Desktop (Linux/Windows) runs playback through
// media_kit/libmpv, whose `af` property accepts an ffmpeg filter graph — that
// is how the equalizer is applied. Android/iOS use just_audio's own backend,
// which has no equivalent here yet, so this is a no-op there.
//
// Everything in this file is best-effort by design: an effects failure must
// degrade to "no effect" and must never throw into the playback path.

import 'dart:io';

import 'package:just_audio_media_kit/mediakit_player.dart';

import '../util/log.dart';

class AudioEffects {
  // macOS is deliberately excluded even though media_kit itself supports it:
  // main.dart only initialises JustAudioMediaKit/AudioServiceMpris for
  // Linux/Windows, so on macOS there is no media_kit player at all and
  // MediaKitPlayer.setActivePlayerProperty would talk to a backend that was
  // never brought up. Showing the EQ UI there would be a dead control.
  static final bool _isDesktop = Platform.isLinux || Platform.isWindows;

  /// Whether an equalizer can actually do anything on this platform. The UI
  /// uses this to hide EQ controls rather than show dead ones.
  static bool get isEqualizerSupported => _isDesktop;

  /// Apply [chain] as mpv's `af` value. An empty string removes all filters.
  ///
  /// Silently does nothing off desktop. May also be a no-op if the
  /// underlying platform player hasn't been created yet (desktop playback
  /// only constructs it lazily, on the first loadCurrent()) — callers are
  /// responsible for re-applying once a player is known to exist; see the
  /// two `ever(...)` hooks registered in main.dart.
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
