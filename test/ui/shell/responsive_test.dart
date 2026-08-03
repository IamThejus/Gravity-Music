import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/ui/shell/responsive.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('isDesktopPlatform tracks the platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(isDesktopPlatform, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(isDesktopPlatform, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(isDesktopPlatform, isFalse);
  });

  test('gridColumns stays at 2 on mobile (no Android regression)', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final w in [320.0, 360.0, 430.0, 600.0, 900.0, 1440.0]) {
      expect(gridColumns(w), 2, reason: 'mobile width $w must be 2 cols');
    }
  });

  test('gridColumns scales with width on desktop, clamped 2..6', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(gridColumns(300), 2); // narrow desktop window
    expect(gridColumns(900), greaterThanOrEqualTo(3));
    expect(gridColumns(4000), 6); // clamped
  });
}
