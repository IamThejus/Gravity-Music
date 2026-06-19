// ui/shell/root_shell.dart
//
// The app's root scaffold. All tabs stay mounted in an IndexedStack
// (scroll/state preserved), but ONLY the active screen is painted — the prior
// Stack+AnimatedOpacity approach kept every screen painting and, during a
// switch, composited two full blurred screens at once (the #1 measured jank
// source). The soft transition feel is preserved with a short fade-through
// applied to the *incoming* screen only (the same language as the app's page
// pushes), so two blurred screens are never composited simultaneously.
// The floating mini-player + nav dock are layered above the content
// (DESIGN.md → "Glass Layer floating above the content stack"). Screens add
// AppSpacing.bottomDock padding so nothing hides behind the dock.

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../queue/queue_screen.dart';
import '../search/search_screen.dart';
import '../theme/motion.dart';
import '../widgets/mini_player.dart';
import 'desktop_shell.dart';
import 'floating_nav_bar.dart';
import 'responsive.dart';

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell>
    with SingleTickerProviderStateMixin {
  int _index = 0;

  // Built once and kept alive by the IndexedStack (state/scroll preserved).
  // Each is wrapped in a RepaintBoundary so a repaint in one tab can never
  // dirty another, and so the active screen rasterizes into its own layer.
  final _screens = const [
    RepaintBoundary(child: HomeScreen()),
    RepaintBoundary(child: SearchScreen()),
    RepaintBoundary(child: LibraryScreen()),
    RepaintBoundary(child: QueueScreen()),
  ];

  // Drives the incoming-screen fade. Rests at 1.0 (Opacity short-circuits the
  // saveLayer at exactly 1.0, so settled tabs cost nothing) and replays 0→1 on
  // each switch. A short fade only — tabs are peer-level, so no scale (peers
  // shouldn't "zoom"); 160ms lands at Spotify-level responsiveness while
  // keeping a whisper of Gravity's softness.
  late final AnimationController _transition = AnimationController(
    vsync: this,
    duration: AppMotion.micro,
    value: 1.0,
  );
  late final Animation<double> _fade =
      _transition.drive(CurveTween(curve: AppMotion.standardCurve));

  void _onTap(int i) {
    // Tapping "Queue" while something plays could also open Now Playing;
    // we keep it as a full tab here for discoverability.
    if (i == _index) return;
    setState(() => _index = i);
    _transition.forward(from: 0.0);
  }

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }

  Widget _content() => FadeTransition(
        opacity: _fade,
        child: IndexedStack(
          index: _index,
          sizing: StackFit.expand,
          children: _screens,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      if (isDesktopWidth(constraints.maxWidth)) {
        return DesktopShell(
          content: _content(),
          currentIndex: _index,
          onTap: _onTap,
        );
      }
      // ── Mobile shell (unchanged) ──
      return Scaffold(
        backgroundColor: AppColors.canvas,
        extendBody: true,
        body: Stack(
          children: [
            Positioned.fill(child: _content()),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const MiniPlayer(),
                      const SizedBox(height: 10),
                      FloatingNavBar(currentIndex: _index, onTap: _onTap),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
