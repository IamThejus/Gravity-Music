import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/quality_prefs.dart';
import 'package:saragama/services/stream_service.dart';

Audio _fmt(int kbps, Codec codec) => Audio(
      itag: 0,
      audioCodec: codec,
      bitrate: kbps * 1000,
      duration: 0,
      loudnessDb: 0,
      url: 'http://x/$kbps',
      size: 0,
    );

void main() {
  group('qualityLabels', () {
    test('positional names match the spec for 1..5 formats', () {
      expect(qualityLabels(1), ['High']);
      expect(qualityLabels(2), ['High', 'Data saver']);
      expect(qualityLabels(3), ['High', 'Medium', 'Data saver']);
      expect(qualityLabels(4), ['High', 'Medium', 'Low', 'Data saver']);
      expect(qualityLabels(5), ['High', 'Medium', 'Low', 'Lower', 'Data saver']);
    });

    test('empty for non-positive counts', () {
      expect(qualityLabels(0), isEmpty);
    });
  });

  group('qualityOptionsFor', () {
    final formats = [
      _fmt(160, Codec.opus),
      _fmt(128, Codec.mp4a),
      _fmt(70, Codec.opus),
    ];

    test('pref 1.0 selects the highest tier', () {
      final opts = qualityOptionsFor(formats, 1.0);
      expect(opts.map((o) => o.label), ['High', 'Medium', 'Data saver']);
      expect(opts[0].selected, isTrue);
      expect(opts[0].kbps, 160);
      expect(opts[0].codecLabel, 'Opus');
      expect(opts[0].detail, '160 kbps · Opus');
    });

    test('pref 0.0 selects the lowest tier', () {
      final opts = qualityOptionsFor(formats, 0.0);
      expect(opts.last.selected, isTrue);
      expect(opts.last.label, 'Data saver');
    });

    test('pref 0.5 selects the middle tier', () {
      final opts = qualityOptionsFor(formats, 0.5);
      expect(opts[1].selected, isTrue);
    });

    test('each option carries the pref that re-selects it', () {
      for (final o in qualityOptionsFor(formats, 1.0)) {
        final reselected = qualityOptionsFor(formats, o.pref);
        expect(reselected.firstWhere((r) => r.selected).label, o.label);
      }
    });

    test('empty formats yields no options', () {
      expect(qualityOptionsFor(const [], 1.0), isEmpty);
    });
  });
}
