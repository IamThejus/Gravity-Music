//
// Responsive helpers. The SHELL is chosen by platform (see [isDesktopPlatform])
// — desktop (Linux/Windows/macOS) always uses the sidebar shell, at any window
// size; mobile always uses the floating-dock shell. Layout details (grid
// columns, collapsed sidebar) still adapt to width within the desktop shell.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../app_theme.dart';

/// True on the desktop platforms that use the sidebar shell. Uses
/// [defaultTargetPlatform] (not dart:io) so it stays web-safe.
bool get isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Below this window width the desktop sidebar collapses to an icon-only rail
/// (still the desktop shell — never the mobile dock).
const double kSidebarCollapseWidth = 760;

/// Number of columns for content grids (home cards, search "Browse", library).
/// Mobile stays at 2 (unchanged). Desktop scales smoothly with the available
/// width so a shrunk window looks right instead of sparse or cramped.
int gridColumns(double width) {
  if (!isDesktopPlatform) return 2; // mobile unchanged
  return (width ~/ 210).clamp(2, 6);
}

/// Bottom padding a scrollable screen reserves for the player chrome.
/// Desktop: the now-playing bar is a real bottom bar outside the scroll area,
/// so a small inset is enough. Mobile: clear the floating dock.
double bottomDockInset(BuildContext context) =>
    isDesktopPlatform ? 24 : AppSpacing.bottomDock;
