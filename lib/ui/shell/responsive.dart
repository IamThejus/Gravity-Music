//
// Width-based responsive helpers. The desktop shell activates at
// [kDesktopBreakpoint]; below it the app renders its mobile shell unchanged.

/// Window width (logical px) at/above which the desktop shell is used.
const double kDesktopBreakpoint = 900;

/// True when the viewport is wide enough for the desktop (sidebar) shell.
bool isDesktopWidth(double width) => width >= kDesktopBreakpoint;

/// Number of grid columns for content grids (search "Browse", library).
/// Phone/narrow widths stay at 2 (preserves the current mobile layout
/// exactly); desktop widths scale by a ~240px target tile, clamped 3..6.
int gridColumns(double width) {
  if (width < kDesktopBreakpoint) return 2;
  return (width ~/ 240).clamp(3, 6);
}
