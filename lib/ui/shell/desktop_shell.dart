// lib/ui/shell/desktop_shell.dart
//
// Desktop chrome: sidebar + content + persistent now-playing bar, with
// top-level media keyboard shortcuts. Only built at desktop widths (RootShell
// decides); the mobile shell is unaffected.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../controllers/player_controller.dart';
import '../app_theme.dart';
import 'desktop_sidebar.dart';
import 'now_playing_bar.dart';

class _PlayPauseIntent extends Intent { const _PlayPauseIntent(); }
class _NextIntent extends Intent { const _NextIntent(); }
class _PrevIntent extends Intent { const _PrevIntent(); }

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
    final pc = Get.find<PlayerController>();
    return FocusableActionDetector(
      autofocus: true,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.space): _PlayPauseIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight): _NextIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _PrevIntent(),
      },
      actions: {
        _PlayPauseIntent: CallbackAction<_PlayPauseIntent>(onInvoke: (_) {
          pc.buttonState.value == PlayButtonState.playing ? pc.pause() : pc.play();
          return null;
        }),
        _NextIntent: CallbackAction<_NextIntent>(onInvoke: (_) { pc.next(); return null; }),
        _PrevIntent: CallbackAction<_PrevIntent>(onInvoke: (_) { pc.prev(); return null; }),
      },
      child: Scaffold(
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
      ),
    );
  }
}
