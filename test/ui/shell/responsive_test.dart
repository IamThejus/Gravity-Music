import 'package:flutter_test/flutter_test.dart';
import 'package:saragama/ui/shell/responsive.dart';

void main() {
  test('isDesktopWidth flips at the breakpoint', () {
    expect(isDesktopWidth(899), isFalse);
    expect(isDesktopWidth(900), isTrue);
    expect(isDesktopWidth(1440), isTrue);
  });

  test('gridColumns stays at 2 for phone widths (no Android regression)', () {
    for (final w in [320.0, 360.0, 411.0, 430.0, 600.0, 899.0]) {
      expect(gridColumns(w), 2, reason: 'phone/narrow width $w must be 2 cols');
    }
  });

  test('gridColumns grows with width on desktop, clamped 3..6', () {
    expect(gridColumns(900), 3);
    expect(gridColumns(1200), greaterThanOrEqualTo(3));
    expect(gridColumns(4000), 6); // clamped
  });
}
