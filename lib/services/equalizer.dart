// services/equalizer.dart
// Pure audio-effects model: equalizer band definitions and presets, mpv
// filter-chain construction (equalizer + mono downmix), and the
// log-frequency resampling Android needs. No Flutter / media_kit / Hive
// imports, so all of it is unit testable without a player or a running app.
// Applying the result is AudioEffects' job; this file only decides what
// should be applied.
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
// implementation will silently drop one effect or the other. Our OWN effects
// already hit exactly this: the equalizer and the mono downmix both live in
// `af`, which is why [buildFilterChain] composes them into one graph rather
// than each having its own writer.
//
// Android does NOT use the chain at all: there the platform's own
// android.media.audiofx.Equalizer is driven band by band, and its bands are
// chosen by the device rather than by us — see [gainAtFrequency].

import 'dart:math' show log;

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
String buildEqualizerChain(List<double> bands, {required bool enabled}) =>
    _wrap(_equalizerNodes(bands, enabled));

/// Filters that collapse stereo to dual mono: both output channels carry the
/// same L+R sum, so the full mix reaches each ear. Used for the accessibility
/// mono-audio setting (single-sided hearing loss, one earbud in).
///
/// The `aformat` node is not optional. `pan` reads `c1`, and a graph that
/// references a channel its input doesn't have is an error — an already-mono
/// source would break the whole chain, taking the equalizer down with it.
/// Forcing a stereo input first makes `pan` safe for any source; verified
/// against a mono input in ffmpeg, which upmixes rather than failing.
const List<String> _kMonoNodes = <String>[
  'aformat=channel_layouts=stereo',
  'pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1',
];

/// Build the complete mpv `af` value for every desktop effect at once.
///
/// This exists because `af` is a single property that can only have ONE
/// writer: pushing the equalizer chain alone would silently drop mono, and
/// vice versa (the hazard this file's header warns about). Everything that
/// wants to filter desktop audio composes into this one graph.
///
/// Returns `''` — no filter at all — when nothing is active. Equalization is
/// applied per channel BEFORE the downmix, so mono hears the same tone curve
/// stereo would.
String buildFilterChain({
  required List<double> bands,
  required bool equalizerEnabled,
  required bool mono,
}) =>
    _wrap([
      ..._equalizerNodes(bands, equalizerEnabled),
      if (mono) ..._kMonoNodes,
    ]);

/// One ffmpeg `equalizer` node per non-flat band; empty when bypassed.
List<String> _equalizerNodes(List<double> bands, bool enabled) {
  if (!enabled) return const [];

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
  return parts;
}

/// Wrap filter nodes in the single lavfi graph mpv's `af` expects, or `''`
/// when there is nothing to apply.
String _wrap(List<String> nodes) =>
    nodes.isEmpty ? '' : 'lavfi=[${nodes.join(',')}]';

/// The gain the [bands] curve implies at an arbitrary centre frequency [hz].
///
/// Needed because Android's equalizer bands are chosen by the DEVICE, not by
/// us — commonly five, at frequencies that don't line up with
/// [kEqFrequencies] — so the user's 10-band curve has to be resampled onto
/// whatever the hardware reports. (Desktop needs none of this: mpv takes our
/// frequencies verbatim.)
///
/// Interpolation is linear in LOG frequency, the axis the bands are actually
/// spaced on and the one the UI draws. A device band at 910 Hz therefore lands
/// roughly midway between the 500 Hz and 1 kHz sliders; interpolating linearly
/// in raw Hz would drag it almost entirely onto 1 kHz and make the middle of
/// the user's curve nearly unreachable.
///
/// Frequencies outside the modelled range clamp to the nearest end band, so a
/// device band at 20 Hz or 20 kHz still tracks the 31 Hz / 16 kHz slider.
/// Tolerates a short or over-long [bands] list, matching
/// [buildEqualizerChain]: persisted preferences can be corrupt, and an
/// equalizer must never break playback.
double gainAtFrequency(List<double> bands, double hz) {
  if (bands.isEmpty || !hz.isFinite || hz <= 0) return 0.0;

  final count =
      bands.length < kEqFrequencies.length ? bands.length : kEqFrequencies.length;
  double gainAt(int i) => bands[i].clamp(kEqMinGain, kEqMaxGain).toDouble();

  if (hz <= kEqFrequencies[0]) return gainAt(0);
  if (hz >= kEqFrequencies[count - 1]) return gainAt(count - 1);

  for (var i = 0; i < count - 1; i++) {
    final hi = kEqFrequencies[i + 1].toDouble();
    if (hz > hi) continue;
    final lo = kEqFrequencies[i].toDouble();
    final t = (log(hz) - log(lo)) / (log(hi) - log(lo));
    return gainAt(i) + (gainAt(i + 1) - gainAt(i)) * t;
  }
  return gainAt(count - 1);
}
