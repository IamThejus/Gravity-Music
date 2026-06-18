// lib/ui/shell/now_playing_bar.dart
//
// Desktop persistent now-playing bar (full window width, docked at the bottom
// of DesktopShell). Reuses PlayerController; mirrors MiniPlayer's behaviour but
// with a seek slider, a volume slider, and an explicit expand button. Hidden
// when nothing is playing.

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/player_controller.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../now_playing/now_playing_screen.dart';
import '../theme/dynamic_color_controller.dart';
import '../ui_helpers.dart';

class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();
    return Obx(() {
      final song = pc.currentSong.value;
      if (song == null) return const SizedBox.shrink();
      return _Bar(pc: pc, song: song);
    });
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

    return Obx(() => Container(
          height: 84,
          decoration: BoxDecoration(
            color: Color.alphaBlend(
                colors.accent.value.withOpacity(0.12), AppColors.glassFill),
            border: const Border(top: BorderSide(color: AppColors.glassBorder)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // ── Track identity (click to expand) ──
              Expanded(
                flex: 3,
                child: InkWell(
                  onTap: () => _openNowPlaying(context),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: art.isEmpty
                          ? Container(
                              width: 48,
                              height: 48,
                              color: AppColors.card,
                              child: const Icon(Icons.music_note_rounded,
                                  size: 20))
                          : CachedNetworkImage(
                              imageUrl: art,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(prettyTitle(song.title),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.trackTitle(size: 14)),
                          Text(prettyTitle(song.artist ?? ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.subtitle(size: 12.5)),
                        ],
                      ),
                    ),
                  ]),
                ),
              ),
              // ── Transport + seek ──
              Expanded(
                flex: 4,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Compact transport row: zero-padding/compact IconButtons so
                    // three default 48px buttons + the seek slider fit the bar
                    // height without overflowing.
                    SizedBox(
                      height: 40,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            onPressed: pc.prev,
                            iconSize: 24,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(Icons.skip_previous_rounded),
                          ),
                          const SizedBox(width: 16),
                          Obx(() => IconButton(
                                iconSize: 32,
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () =>
                                    pc.buttonState.value ==
                                            PlayButtonState.playing
                                        ? pc.pause()
                                        : pc.play(),
                                icon: Icon(
                                    pc.buttonState.value ==
                                            PlayButtonState.playing
                                        ? Icons.pause_circle_filled_rounded
                                        : Icons.play_circle_fill_rounded),
                              )),
                          const SizedBox(width: 16),
                          IconButton(
                            onPressed: pc.next,
                            iconSize: 24,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(Icons.skip_next_rounded),
                          ),
                        ],
                      ),
                    ),
                    Obx(() {
                      final bar = pc.progressBarState.value;
                      final total = bar.total.inMilliseconds.toDouble();
                      final cur = bar.current.inMilliseconds
                          .clamp(0, total <= 0 ? 1 : total.toInt())
                          .toDouble();
                      return SizedBox(
                        height: 28,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            overlayShape: SliderComponentShape.noOverlay,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                          ),
                          child: Slider(
                            value: total <= 0 ? 0 : cur,
                            max: total <= 0 ? 1 : total,
                            activeColor: colors.accent.value,
                            onChanged: total <= 0
                                ? null
                                : (v) => pc.seek(
                                    Duration(milliseconds: v.round())),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              // ── Volume + expand ──
              Expanded(
                flex: 2,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Icon(Icons.volume_up_rounded, size: 20),
                    SizedBox(
                      width: 110,
                      child: Obx(() => Slider(
                            value: pc.volume.value,
                            max: 100,
                            activeColor: colors.accent.value,
                            onChanged: pc.setVolume,
                          )),
                    ),
                    IconButton(
                      tooltip: 'Open now playing',
                      onPressed: () => _openNowPlaying(context),
                      icon: const Icon(
                          Icons.keyboard_arrow_up_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ));
  }

  void _openNowPlaying(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const NowPlayingScreen()));
  }
}
