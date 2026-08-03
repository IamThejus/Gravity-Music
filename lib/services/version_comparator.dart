// services/version_comparator.dart
//
// Semantic-version comparison for the in-app updater. Tolerant of a leading
// 'v' (GitHub tags like `v1.5.0`), build metadata (`1.5.0+3` from pubspec), and
// pre-release suffixes (`1.5.0-beta` — ignored for the numeric compare). Never
// compares version strings lexically.

class VersionComparator {
  /// Returns -1 if [a] < [b], 0 if equal, 1 if [a] > [b] (by major.minor.patch).
  static int compare(String a, String b) {
    final pa = _parse(a);
    final pb = _parse(b);
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i] < pb[i] ? -1 : 1;
    }
    return 0;
  }

  /// True when [candidate] is a strictly newer version than [current].
  static bool isNewer(String candidate, String current) =>
      compare(candidate, current) > 0;

  /// Parse into [major, minor, patch], defaulting missing/garbage parts to 0.
  static List<int> _parse(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // Drop build metadata (+…) and pre-release (-…) before the numeric compare.
    s = s.split('+').first.split('-').first;
    final parts = s.split('.');
    int at(int i) =>
        i < parts.length ? (int.tryParse(parts[i].trim()) ?? 0) : 0;
    return [at(0), at(1), at(2)];
  }
}
