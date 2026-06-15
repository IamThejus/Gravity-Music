// ui/theme/motion.dart
//
// The single source of truth for motion in the app. Every animation pulls its
// duration and curve from here so the whole UI shares one timing language
// (Apple-Music-style: calm, fluid, with natural acceleration + soft settle).
//
//   • fast      (200ms) — taps, press feedback, icon swaps
//   • standard  (300ms) — most UI transitions (crossfades, tab changes, glide)
//   • large     (450ms) — screen / Now-Playing expansion
//   • xlarge    (500ms) — the largest hero morphs
//
// Curves:
//   • standardCurve — easeOutCubic   (accelerate out, soft settle)
//   • emphasized    — easeInOutCubic (symmetric, for color washes)
//   • entrance      — fastOutSlowIn  (Material-spec entrance)
//   • spring        — gentle overshoot for major / playful transitions

import 'package:flutter/material.dart';

import '../app_theme.dart';

class AppMotion {
  AppMotion._();

  // ── Durations ──────────────────────────────────────────────────────────────
  static const Duration micro = Duration(milliseconds: 160); // tab switch / instant peers
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration brisk = Duration(milliseconds: 230); // mini-player track cross-fades
  static const Duration standard = Duration(milliseconds: 300);
  static const Duration large = Duration(milliseconds: 450);
  static const Duration xlarge = Duration(milliseconds: 500);

  // ── Curves ───────────────────────────────────────────────────────────────--
  static const Curve standardCurve = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubic;
  static const Curve entrance = Curves.fastOutSlowIn;

  /// Apple-style "emphasized decelerate" (Material 3): high initial velocity,
  /// long soft settle, NO overshoot. Used for major entrances like the
  /// Now-Playing expansion — fast off the line, smooth to rest.
  static const Curve decelerate = Cubic(0.05, 0.7, 0.1, 1.0);

  /// A restrained spring: tiny overshoot then settle. Reserved for small
  /// playful elements (the nav pill glide); no longer used for screen-scale
  /// transitions, where the overshoot reads as heaviness.
  static const Curve spring = Cubic(0.34, 1.15, 0.64, 1.0);
}

/// App-wide page transition: a soft fade-through with a barely-there scale,
/// replacing the platform (Android zoom) transition so navigation feels
/// continuous and luxurious rather than mechanical. Outgoing screens fade as a
/// new one rises over them.
class FadeThroughPageTransitionsBuilder extends PageTransitionsBuilder {
  const FadeThroughPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final inFade =
        CurvedAnimation(parent: animation, curve: AppMotion.standardCurve);
    final inScale = Tween<double>(begin: 0.985, end: 1.0).animate(
      CurvedAnimation(parent: animation, curve: AppMotion.entrance),
    );
    final outFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: secondaryAnimation, curve: AppMotion.standardCurve),
    );

    return FadeTransition(
      opacity: outFade,
      child: FadeTransition(
        opacity: inFade,
        child: ScaleTransition(scale: inScale, child: child),
      ),
    );
  }
}

/// One shared press-feedback primitive so buttons, cards, and list rows all
/// respond identically: a subtle scale-down on touch that settles back on
/// release (no Android ink ripple). Fires a light haptic by default.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double pressedScale;
  final HitTestBehavior behavior;
  final bool haptic;

  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.pressedScale = 0.96,
    this.behavior = HitTestBehavior.opaque,
    this.haptic = true,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: () {
        if (widget.haptic) AppHaptics.light();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1.0,
        duration: AppMotion.fast,
        curve: AppMotion.standardCurve,
        child: widget.child,
      ),
    );
  }
}
