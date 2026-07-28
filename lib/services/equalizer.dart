// services/equalizer.dart
// Pure equalizer model: band definitions, presets, and mpv filter-chain
// construction. No Flutter / media_kit / Hive imports, so the builder is unit
// testable without a player or a running app. Applying the chain is
// AudioEffects' job; this file only decides what the chain should be.
//
// The chain is an mpv `af` value built from ffmpeg's two-pole peaking
// `equalizer` filter. Verified against mpv 0.41.0: a comma-chained lavfi graph
// applies at runtime via `set_property af` without stalling playback, and an
// empty string removes the filter from the path entirely.
//
// IMPORTANT — `af` is not exclusively ours. media_kit's MediaKitPlayer runs
// with `pitch: true`, so just_audio's setSpeed/setPitch calls make it write
// `af = 'scaletempo:scale=1.00000000'` (scaletempo is how it implements
// tempo/pitch changes). AudioEffects.applyEqualizer overwrites the whole `af`
// property, so pushing our chain removes any scaletempo filter media_kit put
// there, and our own bypass (`af = ''`) removes it too. Today this is benign:
// nothing in lib/ calls setSpeed/setPitch, and even when media_kit sets
// scaletempo itself scale is always 1.0 (a passthrough). But if this app ever
// adds playback-speed control, the two writers will need to compose a single
// `af` value (e.g. our equalizer bands + scaletempo chained together) instead
// of each unconditionally overwriting the property — a naive last-write-wins
// implementation will silently drop one effect or the other.

/// Standard 10-band ISO centre frequencies, in Hz.
const List<int> kEqFrequencies = <int>[
  31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
];

/// Gain limits, in dB.
const double kEqMinGain = -12.0;
const double kEqMaxGain = 12.0;

/// Fixed Q width for every band. Wide enough that 10 bands overlap smoothly.
const double _kBandWidth = 1.0;

/// Preset name -> gains, one per entry in [kEqFrequencies].
const Map<String, List<double>> kEqPresets = <String, List<double>>{
  'Flat':          <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Bass Boost':    <double>[7, 6, 4.5, 2, 0, 0, 0, 0, 0, 0],
  'Treble Boost':  <double>[0, 0, 0, 0, 0, 1, 2.5, 4.5, 6, 7],
  'Vocal':         <double>[-2, -1.5, 0, 2, 4, 4.5, 3.5, 2, 0, -1],
  'Rock':          <double>[5, 4, 2.5, 0, -1, -0.5, 2, 3.5, 4.5, 5],
  'Pop':           <double>[-1, 1, 3, 4.5, 4, 2.5, 0, -1, -1.5, -1.5],
  'Jazz':          <double>[4, 3, 1.5, 2, -1, -1, 0, 1.5, 3, 4],
  'Classical':     <double>[4.5, 3.5, 2.5, 1.5, -1, -1, 0, 2, 3, 4],
  'Electronic':    <double>[6, 5, 1.5, 0, -1.5, 2, 1, 1.5, 4.5, 6],
};

/// Build the mpv `af` value for [bands] (one gain per [kEqFrequencies] entry).
///
/// Returns `''` — meaning "no filter at all" — when [enabled] is false or every
/// band is flat. Bands at exactly 0 dB are omitted so the graph stays as short
/// as possible. Gains are clamped to [kEqMinGain]..[kEqMaxGain], and formatted
/// to one decimal place so the output is deterministic and testable.
///
/// Tolerates a short or over-long [bands] list rather than throwing: persisted
/// preferences can be corrupt, and an equalizer must never break playback.
String buildEqualizerChain(List<double> bands, {required bool enabled}) {
  if (!enabled) return '';

  final parts = <String>[];
  final count =
      bands.length < kEqFrequencies.length ? bands.length : kEqFrequencies.length;
  for (var i = 0; i < count; i++) {
    final gain = bands[i].clamp(kEqMinGain, kEqMaxGain).toDouble();
    // Test the FORMATTED value, not the raw double: a gain like 0.04 rounds
    // to "0.0" at one decimal place and must still be treated as flat, or a
    // rounding artifact would emit a no-op g=0.0 (or g=-0.0) node and defeat
    // the "flat bands emit nothing" intent.
    final gainStr = gain.toStringAsFixed(1);
    if (gainStr == '0.0' || gainStr == '-0.0') continue;
    parts.add('equalizer=f=${kEqFrequencies[i]}'
        ':t=q'
        ':w=${_kBandWidth.toStringAsFixed(1)}'
        ':g=$gainStr');
  }

  if (parts.isEmpty) return '';
  return 'lavfi=[${parts.join(',')}]';
}
