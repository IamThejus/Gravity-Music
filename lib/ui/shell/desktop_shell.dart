// lib/ui/shell/desktop_shell.dart
//
// Desktop chrome: sidebar + content + persistent now-playing bar. Only built at
// desktop widths (RootShell decides); the mobile shell is unaffected.
//
// Keyboard shortcuts used to live here, but this widget sits BELOW the root
// Navigator, so they never fired on pushed routes (Now Playing, Album detail).
// They now live in AppShortcuts, mounted above the Navigator via
// GetMaterialApp's `builder` — see ui/shell/app_shortcuts.dart.

import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'desktop_sidebar.dart';
import 'now_playing_bar.dart';

class DesktopShell extends StatelessWidget {
  final Widget content;
  final int currentIndex;
  final ValueChanged<int> onTap;
  const DesktopShell({
    super.key,
    required this.content,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                DesktopSidebar(currentIndex: currentIndex, onTap: onTap),
                Expanded(child: content),
              ],
            ),
          ),
          const NowPlayingBar(),
        ],
      ),
    );
  }
}
