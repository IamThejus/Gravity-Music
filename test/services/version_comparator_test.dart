import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/services/version_comparator.dart';

void main() {
  group('VersionComparator.compare', () {
    test('spec examples', () {
      expect(VersionComparator.compare('1.4.2', '1.5.0'), -1);
      expect(VersionComparator.compare('1.5.0', '1.5.0'), 0);
      expect(VersionComparator.compare('2.0.0', '1.9.9'), 1);
    });

    test('per-component numeric (not lexical)', () {
      // Lexical would say "1.10.0" < "1.9.0" — numeric must not.
      expect(VersionComparator.compare('1.10.0', '1.9.0'), 1);
      expect(VersionComparator.compare('1.9.0', '1.10.0'), -1);
    });

    test("tolerates leading 'v'", () {
      expect(VersionComparator.compare('v1.5.0', '1.5.0'), 0);
      expect(VersionComparator.compare('v1.6.0', 'v1.5.0'), 1);
    });

    test('ignores build metadata and pre-release', () {
      expect(VersionComparator.compare('1.5.0+3', '1.5.0'), 0);
      expect(VersionComparator.compare('1.5.0-beta', '1.5.0'), 0);
      expect(VersionComparator.compare('1.5.0+9', '1.5.0-rc1'), 0);
    });

    test('missing components default to 0', () {
      expect(VersionComparator.compare('2', '2.0.0'), 0);
      expect(VersionComparator.compare('1.5', '1.5.1'), -1);
    });
  });

  group('VersionComparator.isNewer', () {
    test('strictly newer only', () {
      expect(VersionComparator.isNewer('1.5.0', '1.4.2'), isTrue);
      expect(VersionComparator.isNewer('1.5.0', '1.5.0'), isFalse);
      expect(VersionComparator.isNewer('1.4.0', '1.5.0'), isFalse);
      expect(VersionComparator.isNewer('v1.5.1', '1.5.0'), isTrue);
    });
  });
}
