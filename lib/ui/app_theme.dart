// ui/app_theme.dart
// Central design tokens — import this everywhere for consistency.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const bg         = Color(0xFF000000);
  static const surface    = Color(0xFF111111);
  static const elevated   = Color(0xFF1A1A1A);
  static const border     = Color(0xFF242424);
  static const borderSoft = Color(0xFF1C1C1C);
  static const accent     = Color(0xFFFF3B30);
  static const accentDim  = Color(0x33FF3B30);
  static const white      = Colors.white;
  static const textPrimary   = Colors.white;
  static const textSecondary = Color(0xFF888888);
  static const textMuted     = Color(0xFF555555);

  // ── Gravity "Cinematic Dark" tokens (see references/gravity_music/DESIGN.md) ──
  /// Deep obsidian canvas with a hint of warmth — the Z0 base layer.
  static const canvas       = Color(0xFF0B0B0F);
  /// Z1 content surfaces (cards / inset containers).
  static const card         = Color(0xFF161619);
  /// Glass fill at rest (8% white) and pressed (16%) — Z2 glass layer.
  static const glassFill       = Color(0x14FFFFFF);
  static const glassFillActive = Color(0x29FFFFFF);
  /// 12% white inner border simulating the edge of a glass pane.
  static const glassBorder  = Color(0x1FFFFFFF);
  /// Secondary / tertiary text per the spec (60% / 40% white).
  static const textSecondaryHi = Color(0x99FFFFFF);
  static const textTertiary    = Color(0x66FFFFFF);
}

/// Suspended-containment spacing scale (DESIGN.md → spacing).
class AppSpacing {
  static const double screenMargin = 20; // mandatory floating safe-area margin
  static const double gutter       = 16;
  static const double stackSm      = 8;
  static const double stackMd      = 24;
  static const double stackLg      = 40;
  /// Height reserved at the bottom of scroll views for the floating
  /// mini-player + nav dock, so content never hides behind them.
  static const double bottomDock   = 168;
}

/// Rounded shape scale (DESIGN.md → rounded). Sharp corners are avoided.
class AppRadius {
  static const double sm   = 8;
  static const double md   = 12;
  static const double lg   = 16;
  static const double xl   = 24;
  static const double pill = 999;
}

/// Typography scale — one intentional ladder, benchmarked against Apple Music.
/// Weights step down as text gets more incidental, so the UI reads light and
/// hierarchical rather than uniformly bold:
///   heading  w700  — screen + section titles (was w800)
///   navTitle w700  — collapsed app-bar title
///   title    w600  — card / sheet / playlist names (was w700)
///   trackTitle w500 — track names in lists (the densest, lightest tier)
///   subtitle w400  — artist / secondary (was w500)
///   button   w600  — actions (was w700, ls 1.2)
///   navLabel w600  — bottom-nav labels
///   label    w700  — wide-tracked overlines (e.g. "PLAYLIST")
class AppText {
  // Wide-tracked overline (e.g. "PLAYLIST", "NOW PLAYING")
  static TextStyle label({Color color = AppColors.textSecondary}) =>
      GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: 1.8,
      );

  // Screen + section headings
  static TextStyle heading({double size = 26}) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: -0.4,
      );

  // Collapsed navigation / app-bar title
  static TextStyle navTitle({Color color = AppColors.textPrimary}) =>
      GoogleFonts.inter(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: -0.3,
      );

  // Card / sheet / playlist titles — semibold
  static TextStyle title({double size = 15, Color color = AppColors.textPrimary}) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: -0.1,
      );

  // Track names in lists — lighter than card titles for elegant, scannable rows
  static TextStyle trackTitle(
          {double size = 15.5, Color color = AppColors.textPrimary}) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: FontWeight.w500,
        color: color,
        letterSpacing: -0.1,
      );

  // Secondary subtitle / artist — regular weight, lower emphasis
  static TextStyle subtitle({double size = 13, Color color = AppColors.textSecondary}) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: FontWeight.w400,
        color: color,
      );

  // Caption / metadata
  static TextStyle caption({Color color = AppColors.textMuted}) =>
      GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: color,
      );

  // Bottom-navigation labels
  static TextStyle navLabel({Color color = AppColors.textPrimary}) =>
      GoogleFonts.inter(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: 0.1,
      );

  // Button text
  static TextStyle button({Color color = AppColors.textPrimary}) =>
      GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: 0.2,
      );
}

class AppHaptics {
  static void light()    => HapticFeedback.lightImpact();
  static void medium()   => HapticFeedback.mediumImpact();
  static void selection()=> HapticFeedback.selectionClick();
}

// ── Reusable widgets ──────────────────────────────────────────────────────────

/// Standard thumbnail placeholder
class ThumbPlaceholder extends StatelessWidget {
  final double size;
  final double radius;
  final IconData icon;
  const ThumbPlaceholder({
    super.key,
    this.size = 48,
    this.radius = 8,
    this.icon = Icons.music_note_rounded,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.elevated,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Icon(icon, size: size * 0.38, color: AppColors.textMuted),
      );
}

/// Pill-shaped sheet drag handle
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.textMuted.withOpacity(0.5),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

/// Primary red button
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {
          AppHaptics.light();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 6),
            ],
            Text(label, style: AppText.button()),
          ]),
        ),
      );
}

/// Secondary outlined/filled button
class SecondaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool outlined;
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {
          AppHaptics.light();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: outlined ? Colors.transparent : AppColors.elevated,
            borderRadius: BorderRadius.circular(12),
            border: outlined ? Border.all(color: AppColors.border) : null,
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[
              Icon(icon, color: AppColors.textSecondary, size: 18),
              const SizedBox(width: 6),
            ],
            Text(label, style: AppText.button(color: AppColors.textSecondary)),
          ]),
        ),
      );
}

/// Back button — consistent across all screens
class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: () {
          AppHaptics.light();
          Navigator.of(context).pop();
        },
        icon: const Icon(Icons.arrow_back_ios_new_rounded,
            color: Colors.white, size: 20),
      );
}