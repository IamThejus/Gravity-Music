import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/audio_effects.dart';
import 'package:saragama/services/equalizer.dart';

void main() {
  // These run with no media_kit player ever constructed, which is exactly the
  // "effects must never break playback" case: applying must be a safe no-op.
  test('applying a chain with no active player does not throw', () async {
    final chain = buildEqualizerChain(
      List<double>.filled(kEqFrequencies.length, 0.0)..[0] = 6.0,
      enabled: true,
    );
    await expectLater(AudioEffects.applyEqualizer(chain), completes);
  });

  test('applying an empty (bypass) chain does not throw', () async {
    await expectLater(AudioEffects.applyEqualizer(''), completes);
  });
}
