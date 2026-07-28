// services/volume_mixer.dart
// Single source of truth for the player's output volume.
//
// Two independent inputs decide how loud playback is:
//   - the user's volume slider (0..100)
//   - per-track loudness normalization, derived from YouTube's loudnessDb
//
// They must COMBINE (multiply), not overwrite each other — previously three
// separate call sites each wrote player.setVolume() directly, so moving the
// slider and changing track fought over the same value.
//
// Kept as pure Dart (no just_audio / Hive / Flutter imports) so it is unit
// testable without booting the audio handler, leaving PlaybackEngine as the
// only place that actually calls player.setVolume().

import 'dart:math';

/// Effective linear output volume, 0.0..1.0.
///
/// [userVolume] is the slider position, 0..100.
///
/// [loudnessDb] is YouTube's per-track figure: a POSITIVE value means the
/// content sits that many dB above YouTube's reference level, so the
/// corrective gain is -loudnessDb — the same corrective direction that
/// YouTube's own player applies. Pass 0.0 when unknown (no attenuation).
///
/// [normalize] mirrors the loudness-normalization preference.
///
/// The normalization gain is capped at 1.0: just_audio's setVolume accepts
/// only 0..1, and boosting above unity risks clipping. Real make-up gain
/// requires an AudioPipeline/LoudnessEnhancer and is deliberately out of scope.
double effectiveVolume({
  required double userVolume,
  required double loudnessDb,
  required bool normalize,
}) {
  final normGain =
      normalize ? min(1.0, pow(10.0, -loudnessDb / 20.0).toDouble()) : 1.0;
  return ((userVolume / 100.0) * normGain).clamp(0.0, 1.0);
}
