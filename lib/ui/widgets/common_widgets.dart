// ui/widgets/common_widgets.dart
// Reusable, theme-driven building blocks shared across screens:
// section headers, artwork cards, track rows, and empty states.
// All styling pulls from AppColors / AppText / AppRadius — no magic values.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../theme/motion.dart';
import '../ui_helpers.dart';

/// "PLAYLIST" / "RECENTLY PLAYED" style section heading with optional action.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Optional trailing widget (e.g. a [GlassPillButton]). Takes precedence
  /// over [actionLabel] when provided.
  final Widget? action;

  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenMargin, 0, AppSpacing.screenMargin, AppSpacing.stackSm + 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Text(title, style: AppText.heading(size: 20))),
          if (action != null)
            action!
          else if (actionLabel != null)
            GestureDetector(
              onTap: () {
                AppHaptics.selection();
                onAction?.call();
              },
              child: Text(actionLabel!,
                  style: AppText.caption(color: AppColors.textSecondaryHi)),
            ),
        ],
      ),
    );
  }
}

/// Small, lightweight pill action — translucent glass fill + hairline border,
/// an optional leading icon, and a press-scale. Clearly reads as tappable
/// (unlike plain text) while staying visually quiet. ~34dp tall.
class GlassPillButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onTap;

  const GlassPillButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      pressedScale: 0.95,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: AppColors.glassFill,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.glassBorder, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: AppColors.textPrimary),
              const SizedBox(width: 5),
            ],
            Text(label,
                style: AppText.button(color: AppColors.textPrimary)
                    .copyWith(letterSpacing: 0)),
          ],
        ),
      ),
    );
  }
}

/// Rounded artwork with a subtle inner glow so it never disappears into the
/// black canvas (DESIGN.md → Cards). Falls back to a music-note placeholder.
class ArtImage extends StatelessWidget {
  final String url;
  final double size;
  final double radius;
  final BoxFit fit;

  const ArtImage({
    super.key,
    required this.url,
    this.size = 56,
    this.radius = AppRadius.md,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    final br = BorderRadius.circular(radius);
    // `size: double.infinity` means "fill the available width as a square"
    // (used inside grids, e.g. the Library playlists grid). A fixed height of
    // infinity would be an unbounded-constraint error inside a Column, so in
    // that case we size with AspectRatio(1) and a fixed fallback icon size.
    final bool fill = !size.isFinite;
    final double iconSize = fill ? 44 : size * 0.38;

    // Decode the artwork at (roughly) the resolution it's actually drawn at,
    // not the source resolution. ThumbUtil already picks the right URL tier;
    // this caps the *decoded bitmap* too, cutting decode time + image-cache
    // memory (the Library grid's measured scroll jank). For grid tiles
    // (size == infinity) we derive the on-screen width from a 2-column layout.
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final double logicalW =
        fill ? (MediaQuery.sizeOf(context).width - 56) / 2 : size;
    final int cacheW = (logicalW * dpr).round().clamp(1, 4096);

    final container = Container(
      width: fill ? double.infinity : size,
      height: fill ? double.infinity : size,
      decoration: BoxDecoration(
        borderRadius: br,
        color: AppColors.card,
        boxShadow: const [
          // Subtle inner glow so art never vanishes into the black canvas
          // (Gravity signature). Softened 0x33→0x22 so it reads as a halo,
          // not a heavy ring.
          BoxShadow(color: Color(0x22FFFFFF), blurRadius: 16, spreadRadius: -8),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isEmpty
          ? Center(
              child: Icon(Icons.music_note_rounded,
                  color: AppColors.textTertiary, size: iconSize))
          : CachedNetworkImage(
              imageUrl: url,
              fit: fit,
              memCacheWidth: cacheW,
              memCacheHeight: cacheW,
              placeholder: (_, __) => Container(color: AppColors.card),
              errorWidget: (_, __, ___) => Center(
                child: Icon(Icons.music_note_rounded,
                    color: AppColors.textTertiary, size: iconSize),
              ),
            ),
    );

    return fill ? AspectRatio(aspectRatio: 1, child: container) : container;
  }
}

/// Square card with title + subtitle below — used in horizontal carousels.
class ArtCard extends StatelessWidget {
  final String imageUrl;
  final String title;
  final String? subtitle;
  final double size;
  final String? overline; // e.g. "PLAYLIST"
  final VoidCallback onTap;

  const ArtCard({
    super.key,
    required this.imageUrl,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.overline,
    this.size = 150,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ArtImage(url: imageUrl, size: size, radius: AppRadius.lg),
                if (overline != null)
                  Positioned(
                    left: 12,
                    top: 12,
                    child: Text(overline!,
                        style: AppText.label(color: Colors.white70)),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.stackSm),
            Text(prettyTitle(title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.title(size: 14)),
            if (subtitle != null)
              Text(prettyTitle(subtitle!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.subtitle(size: 12)),
          ],
        ),
      ),
    );
  }
}

/// Standard track row used in lists, queue, search results.
class TrackTile extends StatelessWidget {
  final String imageUrl;
  final String title;
  final String subtitle;
  final String? trailingText;
  final Widget? trailing;
  final bool active;
  final VoidCallback onTap;

  const TrackTile({
    super.key,
    required this.imageUrl,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailingText,
    this.trailing,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    // Pressable (subtle scale) instead of an InkWell ripple, so list rows
    // share the same tap language as cards and buttons (no Android ripple).
    return Pressable(
      onTap: onTap,
      pressedScale: 0.98,
      child: Padding(
        // A touch more vertical air (8→10) for Apple-Music breathing room
        // without inflating the row; keeps density, improves scanability.
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenMargin, vertical: 10),
        child: Row(
          children: [
            ArtImage(url: imageUrl, size: 52),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(prettyTitle(title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // Medium weight (not bold) — lighter, more elegant rows.
                      style: AppText.trackTitle(
                          color: active
                              ? AppColors.white
                              : AppColors.textPrimary)),
                  const SizedBox(height: 3),
                  Text(prettyTitle(subtitle),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.subtitle(size: 13)),
                ],
              ),
            ),
            if (trailing != null) trailing!,
            if (trailing == null && trailingText != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(trailingText!, style: AppText.caption()),
              ),
          ],
        ),
      ),
    );
  }
}

/// Centered, elegant empty state for screens with no content yet.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.stackLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.textTertiary),
            const SizedBox(height: AppSpacing.gutter),
            Text(title, style: AppText.heading(size: 18)),
            const SizedBox(height: AppSpacing.stackSm),
            Text(message,
                textAlign: TextAlign.center,
                style: AppText.subtitle(size: 14)),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.stackMd),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
