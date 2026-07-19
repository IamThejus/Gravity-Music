// ui/shell/app_shortcuts.dart
//
// The app's single source of truth for keyboard shortcuts (desktop-focused,
// harmless on mobile). Mounted via GetMaterialApp's `builder`, which places it
// ABOVE the root Navigator — so shortcuts resolve on every route, including
// pushed full-screen ones (Now Playing, Album/Mix detail). They previously
// lived inside DesktopShell, which sits *below* the Navigator, so any pushed
// route fell outside the focus chain and no key ever fired there.
//
// Every media binding is guarded by [_isEditableFocused] so typing in Search
// still types: Space inserts a space, arrows move the caret, and the
// single-letter bindings (M/L/S/R) type their letters. `isEnabled == false`
// makes a shortcut resolve to "ignored", so the key propagates normally.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../controllers/lyrics_controller.dart';
import '../../controllers/player_controller.dart';
import '../search/search_screen.dart';
import 'root_shell.dart';

// ── Intents ──────────────────────────────────────────────────────────────────

class _PlayPauseIntent extends Intent {
  const _PlayPauseIntent();
}

class _SeekIntent extends Intent {
  const _SeekIntent(this.offset);
  final Duration offset;
}

class _TrackIntent extends Intent {
  const _TrackIntent(this.forward);
  final bool forward;
}

class _VolumeIntent extends Intent {
  const _VolumeIntent(this.delta);
  final double delta;
}

class _MuteIntent extends Intent {
  const _MuteIntent();
}

class _LikeIntent extends Intent {
  const _LikeIntent();
}

class _ShuffleIntent extends Intent {
  const _ShuffleIntent();
}

class _RepeatIntent extends Intent {
  const _RepeatIntent();
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

// ── Typing guard ─────────────────────────────────────────────────────────────

/// True when a text field currently holds focus.
///
/// Only the focus context and its ANCESTORS are inspected. A TextField installs
/// its FocusNode on a `Focus` inside EditableText's subtree, so when a field
/// really has focus EditableText is always an ancestor of the focus context.
///
/// Deliberately does NOT search descendants — SearchScreen's TextField stays
/// permanently mounted in RootShell's IndexedStack, so a descendant walk from
/// any high-level focus node always found an EditableText and disabled every
/// shortcut.
bool _isEditableFocused() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// An action that disables itself while a text field has focus.
class _GuardedAction<T extends Intent> extends Action<T> {
  _GuardedAction(this.run);
  final void Function(T intent) run;

  @override
  bool isEnabled(T intent) => !_isEditableFocused();

  @override
  Object? invoke(T intent) {
    run(intent);
    return null;
  }
}

/// An action that always runs (used for combos that can't collide with typing).
class _AlwaysAction<T extends Intent> extends Action<T> {
  _AlwaysAction(this.run);
  final void Function(T intent) run;

  @override
  Object? invoke(T intent) {
    run(intent);
    return null;
  }
}

// ── Widget ───────────────────────────────────────────────────────────────────

class AppShortcuts extends StatefulWidget {
  final Widget child;
  const AppShortcuts({super.key, required this.child});

  @override
  State<AppShortcuts> createState() => _AppShortcutsState();
}

class _AppShortcutsState extends State<AppShortcuts> {
  /// Level restored when un-muting with `M`.
  double _lastNonZeroVolume = 100;

  PlayerController get _pc => Get.find<PlayerController>();

  void _playPause() {
    final pc = _pc;
    pc.buttonState.value == PlayButtonState.playing ? pc.pause() : pc.play();
  }

  void _seek(Duration offset) {
    final pc = _pc;
    final bar = pc.progressBarState.value;
    var target = bar.current + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (bar.total > Duration.zero && target > bar.total) target = bar.total;
    pc.seek(target);
  }

  void _volume(double delta) {
    final pc = _pc;
    final next = (pc.volume.value + delta).clamp(0.0, 100.0);
    if (next > 0) _lastNonZeroVolume = next;
    pc.setVolume(next);
  }

  void _toggleMute() {
    final pc = _pc;
    final v = pc.volume.value;
    if (v > 0) {
      _lastNonZeroVolume = v;
      pc.setVolume(0);
    } else {
      pc.setVolume(_lastNonZeroVolume <= 0 ? 100 : _lastNonZeroVolume);
    }
  }

  /// Ctrl+F — jump to the Search tab and put the caret in its field.
  void _focusSearch() {
    ShellNav.goToTab?.call(ShellNav.searchTabIndex);
    // The tab switch is a setState; focus after the frame so the field is laid
    // out and can actually take focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Get.isRegistered<SearchUiController>()) {
        Get.find<SearchUiController>().searchFocus.requestFocus();
      }
    });
  }

  /// Esc — step back out of whatever is on top, innermost first.
  void _escape() {
    // 1. Typing → just leave the field.
    if (_isEditableFocused()) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    // 2. Lyrics overlay is drawn inside Now Playing, not as a route.
    if (Get.isRegistered<LyricsController>()) {
      final lyrics = Get.find<LyricsController>();
      if (lyrics.isOpen.value) {
        lyrics.closeLyrics();
        return;
      }
    }
    // 3. Otherwise pop the top route (Now Playing, Album detail, a sheet…).
    //    canPop() keeps Esc from doing anything on the root shell.
    final nav = Get.key.currentState;
    if (nav != null && nav.canPop()) nav.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.space): _PlayPauseIntent(),
        // Bare arrows seek; Ctrl+arrows change track (Spotify/YouTube layout).
        SingleActivator(LogicalKeyboardKey.arrowLeft):
            _SeekIntent(Duration(seconds: -10)),
        SingleActivator(LogicalKeyboardKey.arrowRight):
            _SeekIntent(Duration(seconds: 10)),
        SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
            _TrackIntent(false),
        SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
            _TrackIntent(true),
        SingleActivator(LogicalKeyboardKey.arrowUp): _VolumeIntent(5),
        SingleActivator(LogicalKeyboardKey.arrowDown): _VolumeIntent(-5),
        SingleActivator(LogicalKeyboardKey.keyM): _MuteIntent(),
        SingleActivator(LogicalKeyboardKey.keyL): _LikeIntent(),
        SingleActivator(LogicalKeyboardKey.keyS): _ShuffleIntent(),
        SingleActivator(LogicalKeyboardKey.keyR): _RepeatIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FocusSearchIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PlayPauseIntent: _GuardedAction<_PlayPauseIntent>((_) => _playPause()),
          _SeekIntent: _GuardedAction<_SeekIntent>((i) => _seek(i.offset)),
          _TrackIntent: _GuardedAction<_TrackIntent>(
              (i) => i.forward ? _pc.next() : _pc.prev()),
          _VolumeIntent:
              _GuardedAction<_VolumeIntent>((i) => _volume(i.delta)),
          _MuteIntent: _GuardedAction<_MuteIntent>((_) => _toggleMute()),
          _LikeIntent: _GuardedAction<_LikeIntent>((_) => _pc.toggleLike()),
          _ShuffleIntent:
              _GuardedAction<_ShuffleIntent>((_) => _pc.toggleShuffle()),
          _RepeatIntent: _GuardedAction<_RepeatIntent>((_) => _pc.toggleLoop()),
          // Ctrl+F and Esc stay live while typing — Ctrl+F can't collide with
          // text entry, and Esc's own handler leaves the field first.
          _FocusSearchIntent:
              _AlwaysAction<_FocusSearchIntent>((_) => _focusSearch()),
          _EscapeIntent: _AlwaysAction<_EscapeIntent>((_) => _escape()),
        },
        child: widget.child,
      ),
    );
  }
}
