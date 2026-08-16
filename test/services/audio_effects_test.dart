import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/audio_effects.dart';
import 'package:saragama/services/equalizer.dart';

void main() {
  // These run with no media_kit player and no AudioPipeline ever constructed,
  // which is exactly the "effects must never break playback" case: applying
  // must be a safe no-op.
  test('applying a curve with no active player does not throw', () async {
    final bands = List<double>.filled(kEqFrequencies.length, 0.0)..[0] = 6.0;
    await expectLater(
      AudioEffects.apply(bands: bands, equalizerEnabled: true, mono: false),
      completes,
    );
  });

  test('applying a bypass (disabled) curve does not throw', () async {
    final bands = List<double>.filled(kEqFrequencies.length, 0.0);
    await expectLater(
      AudioEffects.apply(bands: bands, equalizerEnabled: false, mono: true),
      completes,
    );
  });

  test('applying a malformed (empty) curve does not throw', () async {
    await expectLater(
      AudioEffects.apply(
          bands: const <double>[], equalizerEnabled: true, mono: true),
      completes,
    );
  });
}
