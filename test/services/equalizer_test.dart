import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/equalizer.dart';

List<double> flat() => List<double>.filled(kEqFrequencies.length, 0.0);

void main() {
  test('enabled but all bands flat yields bypass (empty string)', () {
    expect(buildEqualizerChain(flat(), enabled: true), '');
  });

  test('disabled yields bypass even with non-zero gains', () {
    final b = flat()..[0] = 6.0;
    expect(buildEqualizerChain(b, enabled: false), '');
  });

  test('a single non-zero band emits exactly one filter with right f and g', () {
    final b = flat()..[0] = 6.0;
    final chain = buildEqualizerChain(b, enabled: true);
    expect(chain, 'lavfi=[equalizer=f=31:t=q:w=1.0:g=6.0]');
  });

  test('flat bands are omitted from the chain', () {
    final b = flat();
    for (var i = 0; i < b.length; i++) {
      b[i] = (i == 4 || i == 6) ? 0.0 : 3.0; // two flat bands
    }
    final chain = buildEqualizerChain(b, enabled: true);
    expect('equalizer='.allMatches(chain).length, 8);
  });

  test('gains outside the allowed range are clamped', () {
    final b = flat()..[0] = 99.0;
    expect(buildEqualizerChain(b, enabled: true), contains('g=12.0'));
    final c = flat()..[0] = -99.0;
    expect(buildEqualizerChain(c, enabled: true), contains('g=-12.0'));
  });

  test('every preset has exactly 10 gains, all within range', () {
    expect(kEqPresets.containsKey('Flat'), isTrue);
    for (final entry in kEqPresets.entries) {
      expect(entry.value.length, kEqFrequencies.length,
          reason: '${entry.key} must have ${kEqFrequencies.length} bands');
      for (final g in entry.value) {
        expect(g, inInclusiveRange(kEqMinGain, kEqMaxGain),
            reason: '${entry.key} has an out-of-range gain');
      }
    }
  });

  test('the Flat preset produces bypass', () {
    expect(buildEqualizerChain(kEqPresets['Flat']!, enabled: true), '');
  });

  test('output is deterministic for the same input', () {
    final b = flat()..[2] = 4.5;
    expect(buildEqualizerChain(b, enabled: true),
        buildEqualizerChain(b, enabled: true));
  });

  test('a short/corrupt band list does not throw', () {
    expect(() => buildEqualizerChain([1.0, 2.0], enabled: true), returnsNormally);
  });

  // ── buildFilterChain: equalizer and mono share one `af` value ────────────

  group('buildFilterChain', () {
    test('nothing enabled yields bypass', () {
      expect(
        buildFilterChain(bands: flat(), equalizerEnabled: false, mono: false),
        '',
      );
    });

    test('mono alone emits the downmix in a single lavfi graph', () {
      final chain =
          buildFilterChain(bands: flat(), equalizerEnabled: false, mono: true);
      expect(chain, startsWith('lavfi=['));
      expect(chain, endsWith(']'));
      expect(chain, contains('pan=stereo'));
      expect(chain, isNot(contains('equalizer=')));
    });

    test('mono forces a stereo input before pan', () {
      // pan reads c1; without the aformat guard an already-mono source would
      // reference a channel that doesn't exist and break the whole graph.
      final chain =
          buildFilterChain(bands: flat(), equalizerEnabled: false, mono: true);
      expect(
        chain.indexOf('aformat=channel_layouts=stereo'),
        lessThan(chain.indexOf('pan=')),
      );
    });

    test('equalizer and mono compose into ONE graph, neither dropped', () {
      final b = flat()..[0] = 6.0;
      final chain =
          buildFilterChain(bands: b, equalizerEnabled: true, mono: true);
      expect('lavfi=['.allMatches(chain).length, 1);
      expect(chain, contains('equalizer=f=31'));
      expect(chain, contains('pan=stereo'));
    });

    test('equalization is applied before the downmix', () {
      final b = flat()..[9] = -4.0;
      final chain =
          buildFilterChain(bands: b, equalizerEnabled: true, mono: true);
      expect(chain.indexOf('equalizer='), lessThan(chain.indexOf('pan=')));
    });

    test('with mono off it matches buildEqualizerChain exactly', () {
      final b = flat()
        ..[1] = 3.0
        ..[7] = -2.5;
      expect(
        buildFilterChain(bands: b, equalizerEnabled: true, mono: false),
        buildEqualizerChain(b, enabled: true),
      );
    });

    test('a disabled equalizer does not suppress mono', () {
      final b = flat()..[0] = 6.0;
      final chain =
          buildFilterChain(bands: b, equalizerEnabled: false, mono: true);
      expect(chain, contains('pan=stereo'));
      expect(chain, isNot(contains('equalizer=')));
    });
  });

  // ── gainAtFrequency: resampling the 10-band curve onto device bands ───────

  group('gainAtFrequency', () {
    test('returns a band gain exactly at its own centre frequency', () {
      final b = flat();
      for (var i = 0; i < b.length; i++) {
        b[i] = i - 4.0; // distinct value per band
      }
      for (var i = 0; i < kEqFrequencies.length; i++) {
        expect(gainAtFrequency(b, kEqFrequencies[i].toDouble()), closeTo(b[i], 1e-9));
      }
    });

    test('clamps to the end bands outside the modelled range', () {
      final b = flat()
        ..[0] = 8.0
        ..[9] = -6.0;
      expect(gainAtFrequency(b, 20), 8.0);
      expect(gainAtFrequency(b, 1), 8.0);
      expect(gainAtFrequency(b, 20000), -6.0);
    });

    test('interpolates in log space, not linear Hz', () {
      // 707 Hz is the geometric mean of 500 and 1000, so it must land exactly
      // halfway. Linear-in-Hz interpolation would put it at ~0.41 of the way.
      final b = flat()
        ..[4] = 0.0 // 500 Hz
        ..[5] = 10.0; // 1 kHz
      expect(gainAtFrequency(b, 707.10678), closeTo(5.0, 0.01));
      // And the midpoint in raw Hz (750) must NOT be the halfway gain.
      expect(gainAtFrequency(b, 750), greaterThan(5.0));
    });

    test('a flat curve is flat at every frequency', () {
      for (final hz in <double>[20, 91, 910, 3600, 14000, 22050]) {
        expect(gainAtFrequency(flat(), hz), 0.0);
      }
    });

    test('out-of-range stored gains are clamped', () {
      final b = flat()..[0] = 99.0;
      expect(gainAtFrequency(b, 31), kEqMaxGain);
      final c = flat()..[9] = -99.0;
      expect(gainAtFrequency(c, 16000), kEqMinGain);
    });

    test('malformed input returns flat rather than throwing', () {
      expect(gainAtFrequency(const [], 1000), 0.0);
      expect(gainAtFrequency(flat(), double.nan), 0.0);
      expect(gainAtFrequency(flat(), 0), 0.0);
      expect(gainAtFrequency(flat(), -100), 0.0);
      expect(() => gainAtFrequency([3.0, 6.0], 5000), returnsNormally);
    });

    test('a short band list clamps to its own last band', () {
      // Only two bands stored (31 Hz, 62 Hz): everything above 62 Hz must
      // track band 1 rather than reading past the end of the list.
      expect(gainAtFrequency([3.0, 6.0], 8000), 6.0);
    });
  });
}
