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

/// True when a text field currently holds focus, so media keyboard shortcuts
/// (Space / arrows) must NOT fire — Space would otherwise toggle playback and
/// arrows would skip tracks while the user is typing in Search.
///
/// The focused node's own widget is often NOT the `EditableText` itself (it can
/// be a wrapping Focus, or EditableText can sit just below the focus context),
/// so we look for an `EditableText` at the focus context, among its ancestors,
/// or among its descendants.
bool _isEditableFocused() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) return true;
  var found = false;
  void search(Element e) {
    if (found) return;
    if (e.widget is EditableText) {
      found = true;
      return;
    }
    e.visitChildElements(search);
  }
  ctx.visitChildElements(search);
  return found;
}

/// A media shortcut action that disables itself while typing in a text field.
/// `isEnabled == false` makes the shortcut resolve to "ignored", so the key
/// propagates normally (Space types a space, arrows move the caret).
class _GuardedAction<T extends Intent> extends Action<T> {
  _GuardedAction(this.run);
  final VoidCallback run;

  @override
  bool isEnabled(T intent) => !_isEditableFocused();

  @override
  Object? invoke(T intent) {
    run();
    return null;
  }
}

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
        _PlayPauseIntent: _GuardedAction<_PlayPauseIntent>(() =>
            pc.buttonState.value == PlayButtonState.playing
                ? pc.pause()
                : pc.play()),
        _NextIntent: _GuardedAction<_NextIntent>(pc.next),
        _PrevIntent: _GuardedAction<_PrevIntent>(pc.prev),
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
