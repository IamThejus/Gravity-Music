// ui/home/mix_detail_screen.dart
//
// Opens a curated Mix (from MixesService / the /mixes endpoint) as a playlist:
// a hero header, Play / Shuffle, and the track list. The Mix already carries
// its full track list inline, so this needs no extra fetch. Playback is
// delegated to PlayerController (no logic duplicated here).

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/player_controller.dart';
import '../../services/mixes_service.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../ui_helpers.dart';
import '../widgets/common_widgets.dart';
import '../widgets/mini_player.dart';

class MixDetailScreen extends StatelessWidget {
  final Mix mix;
  const MixDetailScreen({super.key, required this.mix});

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();
    final tracks = mix.tracks;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: ScreenWithMiniPlayer(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              backgroundColor: AppColors.canvas,
              pinned: true,
              // 320 (not 280): the header Column — 80px top pad + 150 art +
              // 12 gap + title + subtitle + 12 bottom pad — needs ~307px and
              // overflowed by 27px at 280, clipping the title under the
              // RenderFlex warning stripes.
              expandedHeight: 320,
              leading: const AppBackButton(),
              flexibleSpace: FlexibleSpaceBar(
                background: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.screenMargin, 80, AppSpacing.screenMargin, 12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // mix.image is a saragama mood image — used as-is.
                      ArtImage(url: mix.image, size: 150, radius: AppRadius.lg),
                      const SizedBox(height: 12),
                      Text(mix.title,
                          style: AppText.heading(size: 24),
                          textAlign: TextAlign.center),
                      Text('${mix.trackCount} songs',
                          style: AppText.subtitle(size: 13)),
                    ],
                  ),
                ),
              ),
            ),
            if (tracks.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.queue_music_rounded,
                  title: 'Mix unavailable',
                  message: 'This mix has no tracks right now. Try again later.',
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.screenMargin, 8,
                      AppSpacing.screenMargin, AppSpacing.gutter),
                  child: Row(
                    children: [
                      Expanded(
                        child: PrimaryButton(
                          label: 'Play',
                          icon: Icons.play_arrow_rounded,
                          onTap: () => pc.playAllMedia(
                              tracks.map((t) => t.toMediaItem()).toList()),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.gutter),
                      Expanded(
                        child: SecondaryButton(
                          label: 'Shuffle',
                          icon: Icons.shuffle_rounded,
                          onTap: () => pc.playShuffledMedia(
                              tracks.map((t) => t.toMediaItem()).toList()),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) {
                    final t = tracks[i];
                    return TrackTile(
                      imageUrl: sizedThumb(t.thumbnail, ThumbnailSize.tile),
                      title: t.title,
                      subtitle: t.artist,
                      trailingText: t.duration,
                      onTap: () => pc.playAllMedia(
                          tracks.map((x) => x.toMediaItem()).toList(),
                          startIndex: i),
                    );
                  },
                  childCount: tracks.length,
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}
