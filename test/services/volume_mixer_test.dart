import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/volume_mixer.dart';

void main() {
  test('normalization off: output is just the user volume', () {
    expect(effectiveVolume(userVolume: 100, loudnessDb: 7.14, normalize: false),
        1.0);
    expect(effectiveVolume(userVolume: 50, loudnessDb: 7.14, normalize: false),
        closeTo(0.5, 1e-9));
    expect(effectiveVolume(userVolume: 0, loudnessDb: 7.14, normalize: false),
        0.0);
  });

  test('loud tracks are attenuated by exactly -loudnessDb', () {
    // Real measured values from YouTube manifests.
    expect(effectiveVolume(userVolume: 100, loudnessDb: 7.14, normalize: true),
        closeTo(0.4395, 0.001));
    expect(effectiveVolume(userVolume: 100, loudnessDb: 5.71, normalize: true),
        closeTo(0.5183, 0.001));
    expect(effectiveVolume(userVolume: 100, loudnessDb: 0.98, normalize: true),
        closeTo(0.8934, 0.001));
  });

  test('unknown loudness (0 dB) means no attenuation', () {
    expect(effectiveVolume(userVolume: 100, loudnessDb: 0.0, normalize: true),
        1.0);
  });

  test('quiet tracks clamp to unity — never boosted above 1.0', () {
    expect(effectiveVolume(userVolume: 100, loudnessDb: -3.0, normalize: true),
        1.0);
    expect(effectiveVolume(userVolume: 100, loudnessDb: -20.0, normalize: true),
        1.0);
  });

  test('user volume multiplies with the normalization gain', () {
    expect(effectiveVolume(userVolume: 50, loudnessDb: 7.14, normalize: true),
        closeTo(0.2198, 0.001));
  });

  test('output always stays within 0..1', () {
    for (final u in [0.0, 1.0, 50.0, 99.0, 100.0]) {
      for (final db in [-30.0, -5.0, 0.0, 5.71, 20.0]) {
        expect(
          effectiveVolume(userVolume: u, loudnessDb: db, normalize: true),
          inInclusiveRange(0.0, 1.0),
        );
      }
    }
  });
}
