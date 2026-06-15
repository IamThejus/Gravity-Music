// ui/widgets/mini_player.dart
//
// Persistent floating glass mini-player (DESIGN.md → Mini-Player). Sits above
// the floating nav, tinted by the current artwork, with a 2px progress line
// at the very bottom of the glass. Tapping expands to NowPlayingScreen via a
// shared-element Hero on the artwork. Drives the existing PlayerController.
//
// Motion notes:
//   • The bar fades + slides in/out when playback starts/stops (AnimatedSwitcher).
//   • Artwork and title cross-fade on track change (keyed AnimatedSwitchers).
//   • The progress line interpolates between position ticks (TweenAnimationBuilder)
//     so it glides instead of stepping.
//   • Rebuilds are isolated: the outer Obx watches only the song, a nested Obx
//     watches only progress, and the transport button watches only buttonState —
//     so a position tick repaints a 2px line, not the whole bar.

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/player_controller.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../now_playing/now_playing_screen.dart';
import '../theme/dynamic_color_controller.dart';
import '../theme/glass.dart';
import '../theme/motion.dart';
import '../ui_helpers.dart';

/// Wraps a pushed full-screen route's body with the floating mini-player
/// docked at the bottom. The root dock (RootShell) is covered by pushed
/// routes, so detail screens (playlist, liked, downloads, mixes) re-dock one
/// here for continuity. Content should reserve ~96px of bottom padding.
class ScreenWithMiniPlayer extends StatelessWidget {
  final Widget child;
  const ScreenWithMiniPlayer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: MiniPlayer(),
            ),
          ),
        ),
      ],
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();

    return AnimatedSwitcher(
      duration: AppMotion.standard,
      switchInCurve: AppMotion.standardCurve,
      switchOutCurve: AppMotion.standardCurve,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SizeTransition(
          sizeFactor: anim,
          axisAlignment: -1,
          child: child,
        ),
      ),
      // Outer Obx watches ONLY the song, so track ticks don't rebuild this.
      child: Obx(() {
        final song = pc.currentSong.value;
        if (song == null) return const SizedBox.shrink(key: ValueKey('mp-empty'));
        return KeyedSubtree(
          key: const ValueKey('mp-bar'),
          child: _Bar(pc: pc, song: song),
        );
      }),
    );
  }
}

class _Bar extends StatelessWidget {
  final PlayerController pc;
  final MediaItem song;
  const _Bar({required this.pc, required this.song});

  @override
  Widget build(BuildContext context) {
    final colors = Get.find<DynamicColorController>();
    final art = sizedThumb(song.artUri?.toString(), ThumbnailSize.micro);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenMargin),
      child: GestureDetector(
        onTap: () => _openNowPlaying(context),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -100) _openNowPlaying(context);
        },
        // Tint follows the artwork accent; rebuilds only when the accent changes.
        child: Obx(() => GlassContainer(
              radius: AppRadius.lg,
              blur: 24,
              shadow: kGlassShadow,
              fill: Color.alphaBlend(
                  colors.accent.value.withOpacity(0.14), AppColors.glassFill),
              child: SizedBox(
                height: 62,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 8),
                        Hero(
                          tag: kNowPlayingArtTag,
                          // Straight-line rect tween: the artwork scales up
                          // directly instead of the default arc swoop, which
                          // reads cleaner and faster on a vertical expansion.
                          createRectTween: (begin, end) =>
                              RectTween(begin: begin, end: end),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            child: AnimatedSwitcher(
                              duration: AppMotion.brisk,
                              switchInCurve: AppMotion.standardCurve,
                              child: art.isEmpty
                                  ? Container(
                                      key: const ValueKey('mp-art-ph'),
                                      width: 46,
                                      height: 46,
                                      color: AppColors.card,
                                      child: const Icon(Icons.music_note_rounded,
                                          size: 20,
                                          color: AppColors.textTertiary))
                                  : CachedNetworkImage(
                                      key: ValueKey(art),
                                      imageUrl: art,
                                      width: 46,
                                      height: 46,
                                      memCacheWidth:
                                          (46 * MediaQuery.devicePixelRatioOf(context))
                                              .round(),
                                      memCacheHeight:
                                          (46 * MediaQuery.devicePixelRatioOf(context))
                                              .round(),
                                      fit: BoxFit.cover),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: AppMotion.brisk,
                            switchInCurve: AppMotion.standardCurve,
                            transitionBuilder: (child, anim) => FadeTransition(
                              opacity: anim,
                              child: SlideTransition(
                                position: Tween(
                                        begin: const Offset(0, 0.25),
                                        end: Offset.zero)
                                    .animate(anim),
                                child: child,
                              ),
                            ),
                            child: Column(
                              key: ValueKey(song.id),
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(prettyTitle(song.title),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.trackTitle(size: 14)),
                                const SizedBox(height: 1),
                                Text(prettyTitle(song.artist ?? ''),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.subtitle(size: 12.5)),
                              ],
                            ),
                          ),
                        ),
                        _MiniButton(
                          builder: () {
                            final state = pc.buttonState.value;
                            if (state == PlayButtonState.loading) {
                              return const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              );
                            }
                            return Icon(
                              state == PlayButtonState.playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              key: ValueKey(state),
                              color: Colors.white,
                              size: 28,
                            );
                          },
                          onTap: () => pc.buttonState.value ==
                                  PlayButtonState.playing
                              ? pc.pause()
                              : pc.play(),
                        ),
                        _MiniButton(
                          builder: () => const Icon(Icons.skip_next_rounded,
                              key: ValueKey('next'),
                              color: Colors.white,
                              size: 26),
                          onTap: pc.next,
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                    // Progress line — same gliding 2px line, but painted via a
                    // CustomPaint inside its own RepaintBoundary. The glide
                    // still ticks every frame during playback, yet each frame
                    // is now a trivial rect paint in an isolated layer: no
                    // FractionallySizedBox relayout, and crucially it no longer
                    // dirties the GlassContainer's BackdropFilter (which would
                    // otherwise re-blur the backdrop ~33×/sec while "idle").
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _MiniProgress(),
                    ),
                  ],
                ),
              ),
            )),
      ),
    );
  }

  void _openNowPlaying(BuildContext context) {
    AppHaptics.light();
    Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 400),
      reverseTransitionDuration: AppMotion.standard,
      pageBuilder: (_, __, ___) => const NowPlayingScreen(),
      transitionsBuilder: (_, anim, __, child) {
        // Decelerate (no overshoot) rise; the artwork itself morphs via the
        // shared Hero, so the whole thing reads as one object expanding fast
        // off the line and settling softly — Apple-Music style.
        final curved = CurvedAnimation(parent: anim, curve: AppMotion.decelerate);
        return FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: AppMotion.standardCurve),
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.06), end: Offset.zero)
                .animate(curved),
            child: child,
          ),
        );
      },
    ));
  }
}

/// The 2px progress line glued to the bottom of the mini-player glass.
/// Self-contained (const) and isolated in a RepaintBoundary so its per-frame
/// glide never re-rasters the BackdropFilter above it. Paints a single rect —
/// no FractionallySizedBox relayout.
class _MiniProgress extends StatelessWidget {
  const _MiniProgress();

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();
    final colors = Get.find<DynamicColorController>();
    return RepaintBoundary(
      child: Obx(() {
        final bar = pc.progressBarState.value;
        final progress = bar.total.inMilliseconds > 0
            ? (bar.current.inMilliseconds / bar.total.inMilliseconds)
                .clamp(0.0, 1.0)
            : 0.0;
        final color = colors.accent.value;
        return TweenAnimationBuilder<double>(
          tween: Tween(end: progress),
          duration: const Duration(milliseconds: 600),
          curve: Curves.linear,
          builder: (_, value, __) => CustomPaint(
            painter: _ProgressLinePainter(value, color),
            child: const SizedBox(height: 2, width: double.infinity),
          ),
        );
      }),
    );
  }
}

class _ProgressLinePainter extends CustomPainter {
  final double value;
  final Color color;
  const _ProgressLinePainter(this.value, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (value <= 0) return;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * value, size.height),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ProgressLinePainter old) =>
      old.value != value || old.color != color;
}

/// Obx-wrapped tap target for the mini-player transport buttons.
class _MiniButton extends StatelessWidget {
  final Widget Function() builder;
  final VoidCallback onTap;
  const _MiniButton({required this.builder, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        AppHaptics.light();
        onTap();
      },
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        child: Obx(() {
          // Touch buttonState so the icon rebuilds on play/pause.
          Get.find<PlayerController>().buttonState.value;
          return AnimatedSwitcher(
            duration: AppMotion.fast,
            switchInCurve: AppMotion.standardCurve,
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: builder(),
          );
        }),
      ),
    );
  }
}
