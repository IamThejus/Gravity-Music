// models/hm_streaming_data.dart
// Mirrors HarmonyMusic's HMStreamingData model, extended to carry the full
// ranked list of audio formats so the player can offer a per-track quality
// picker instead of a fixed low/high pair.

import '../services/stream_service.dart';

class HMStreamingData {
  final bool playable;
  final String statusMSG;

  /// Audio formats ranked best-first (index 0 = highest bitrate). The number
  /// of entries varies per song, so the user's quality preference is stored as
  /// a normalized 0.0–1.0 value and mapped onto this list (see [setQualityPref]).
  final List<Audio> formats;

  Audio? _audio; // selected based on quality preference

  HMStreamingData({
    required this.playable,
    required this.statusMSG,
    List<Audio>? formats,
  }) : formats = formats ?? const [] {
    _audio = this.formats.isNotEmpty ? this.formats.first : null;
  }

  factory HMStreamingData.fromJson(Map<String, dynamic> json) {
    final raw = json['formats'];
    final List<Audio> formats;
    if (raw is List) {
      formats = raw
          .map((e) => Audio.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } else {
      // Backward-compat: older cache entries stored only a low/high pair.
      formats = [
        if (json['highQualityAudio'] != null)
          Audio.fromJson(Map<String, dynamic>.from(json['highQualityAudio'])),
        if (json['lowQualityAudio'] != null)
          Audio.fromJson(Map<String, dynamic>.from(json['lowQualityAudio'])),
      ];
    }
    return HMStreamingData(
      playable: json['playable'] ?? false,
      statusMSG: json['statusMSG'] ?? '',
      formats: formats,
    );
  }

  /// Select a format by a normalized preference: 1.0 = highest available
  /// bitrate, 0.0 = lowest (data saver). Maps onto however many formats this
  /// particular track exposes, so a single preference works across songs with
  /// differing format counts.
  void setQualityPref(double pref) {
    if (formats.isEmpty) {
      _audio = null;
      return;
    }
    final p = pref.clamp(0.0, 1.0);
    final idx = ((1.0 - p) * (formats.length - 1)).round();
    _audio = formats[idx.clamp(0, formats.length - 1)];
  }

  Audio? get audio =>
      _audio ?? (formats.isNotEmpty ? formats.first : null);
}
