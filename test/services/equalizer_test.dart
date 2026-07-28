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
}
