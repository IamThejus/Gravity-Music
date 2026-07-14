// services/quality_prefs.dart
// Streaming-quality preference: shared helpers for reading/writing the user's
// quality tier and turning a track's available formats into a labelled,
// user-facing option list.
//
// The preference is stored as a normalized double in AppPrefs under
// 'qualityPref' (1.0 = highest bitrate, 0.0 = data saver). It is deliberately
// relative rather than an absolute itag/index, because the number of formats
// YouTube exposes varies per song — see HMStreamingData.setQualityPref.

import 'package:hive/hive.dart';

import '../models/hm_streaming_data.dart';
import 'stream_service.dart';

/// Read the normalized quality preference (1.0 = high … 0.0 = data saver).
/// Falls back to the legacy int `streamingQuality` (1→1.0, 0→0.0) for users
/// upgrading from the old two-state toggle, defaulting to high.
double readQualityPref() {
  final box = Hive.box('AppPrefs');
  final stored = box.get('qualityPref');
  if (stored is num) return stored.toDouble().clamp(0.0, 1.0);
  final legacy = box.get('streamingQuality');
  return legacy == 0 ? 0.0 : 1.0;
}

/// Persist the normalized quality preference.
void writeQualityPref(double pref) {
  Hive.box('AppPrefs').put('qualityPref', pref.clamp(0.0, 1.0));
}

/// Positional tier names for a track exposing [n] formats (best-first). The top
/// is always "High" and the bottom always "Data saver"; middle slots fill from
/// Medium → Low → Lower. E.g. 2→[High, Data saver], 3→[High, Medium, Data
/// saver], 4→[High, Medium, Low, Data saver].
List<String> qualityLabels(int n) {
  if (n <= 0) return const [];
  if (n == 1) return const ['High'];
  const middle = ['Medium', 'Low', 'Lower', 'Minimal'];
  final labels = List<String>.filled(n, 'Low');
  labels[0] = 'High';
  labels[n - 1] = 'Data saver';
  for (var i = 1; i < n - 1; i++) {
    labels[i] = (i - 1) < middle.length ? middle[i - 1] : 'Low';
  }
  return labels;
}

/// A single selectable quality tier for the current track.
class QualityOption {
  final String label; // High / Medium / … / Data saver
  final int kbps; // 0 for offline/unknown
  final Codec codec;
  final double pref; // normalized value to persist if chosen
  final bool selected; // matches the current preference

  const QualityOption({
    required this.label,
    required this.kbps,
    required this.codec,
    required this.pref,
    required this.selected,
  });

  String get codecLabel => codec == Codec.opus ? 'Opus' : 'AAC';

  /// e.g. "160 kbps · Opus" (kbps omitted when unknown, e.g. offline files).
  String get detail =>
      kbps > 0 ? '$kbps kbps · $codecLabel' : codecLabel;
}

/// Build the labelled option list for a track's ranked [formats], marking the
/// one that matches [pref] as selected. Empty when the track has no formats.
List<QualityOption> qualityOptionsFor(List<Audio> formats, double pref) {
  final n = formats.length;
  if (n == 0) return const [];
  final labels = qualityLabels(n);
  final p = pref.clamp(0.0, 1.0);
  final selIdx = ((1.0 - p) * (n - 1)).round().clamp(0, n - 1);
  return [
    for (var i = 0; i < n; i++)
      QualityOption(
        label: labels[i],
        kbps: (formats[i].bitrate / 1000).round(),
        codec: formats[i].audioCodec,
        pref: n == 1 ? 1.0 : (1.0 - i / (n - 1)),
        selected: i == selIdx,
      ),
  ];
}

/// Parse the ranked formats for [videoId] from the URL cache, if present.
/// Returns empty when the song hasn't been resolved yet or is offline-only.
List<Audio> cachedFormatsFor(String videoId) {
  final cached = Hive.box('SongsUrlCache').get(videoId);
  if (cached is! Map) return const [];
  return HMStreamingData.fromJson(Map<String, dynamic>.from(cached)).formats;
}
