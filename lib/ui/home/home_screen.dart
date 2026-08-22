// ui/home/home_screen.dart
//
// Personalized home. Sections are backed by REAL signals only:
//   • greeting        → local time of day
//   • Recently Played → PlayerController.searchHistory (tracks you've played)
//   • Made For You    → curated mixes from the saragama /mixes endpoint
//   • Your Playlists  → LibraryService.getPlaylists()
//   • Liked Songs     → LibraryService.getLiked()
// Playback is delegated to PlayerController.playWithRecommendations / playAll.

import 'package:get/get.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../services/library_service.dart';
import '../../services/mixes_service.dart';
import '../../services/personalized_mixes_service.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../library/library_screen.dart';
import '../shell/responsive.dart';
import '../theme/glass.dart';
import '../ui_helpers.dart';
import '../widgets/common_widgets.dart';
import 'mix_detail_screen.dart';

// ── Controller ───────────────────────────────────────────────────────────────

class HomeController extends GetxController {
  /// Curated mixes for the "Made For You" section (saragama /mixes endpoint).
  final mixes = <Mix>[].obs;
  final loadingMixes = false.obs;

  @override
  void onInit() {
    super.onInit();
    loadMixes();
  }

  Future<void> loadMixes({bool forceRefresh = false}) async {
    loadingMixes.value = true;
    try {
      // Personalized mixes first; fall back to curated mood mixes when the
      // taste profile is too thin or personalization yields nothing.
      var loaded = await PersonalizedMixesService.getMixes(
          forceRefresh: forceRefresh);
      if (loaded.isEmpty) {
        loaded = await MixesService.getMixes(forceRefresh: forceRefresh);
      }
      mixes.assignAll(loaded);
    } finally {
      loadingMixes.value = false;
    }
  }
}

// ── Screen ───────────────────────────────────────────────────────────────────

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final home = Get.put(HomeController());
    final pc = Get.find<PlayerController>();

    return RefreshIndicator(
      color: Colors.white,
      backgroundColor: AppColors.card,
      onRefresh: () => home.loadMixes(forceRefresh: true),
      child: CustomScrollView(
        slivers: [
          // ── Collapsing large title (Apple-Music large-title behaviour) ──
          // "Gravity" stays visible while scrolling: large at rest, shrinking
          // into a pinned nav title on scroll. The greeting fades out with the
          // FlexibleSpaceBar background, so brand presence + orientation are
          // always maintained without a heavy sticky header.
          SliverAppBar(
            pinned: true,
            expandedHeight: 124,
            backgroundColor: AppColors.canvas,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            automaticallyImplyLeading: false,
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.screenMargin),
                child: GlassIconButton(
                  icon: Icons.favorite_rounded,
                  iconColor: AppColors.accent,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const LikedSongsScreen())),
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsetsDirectional.only(
                  start: AppSpacing.screenMargin, bottom: 14),
              expandedTitleScale: 1.85, // navTitle 17 → ~31 expanded
              title: Text('Gravity', style: AppText.navTitle()),
              background: SafeArea(
                bottom: false,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(
                        left: AppSpacing.screenMargin, bottom: 46),
                    child: Text(greetingForNow(),
                        style: AppText.subtitle(size: 15)),
                  ),
                ),
              ),
            ),
          ),
          // ── Recently Played ──────────────────────────────────────────
          SliverToBoxAdapter(
            child: Obx(() {
              final recent = pc.searchHistory;
              if (recent.isEmpty) return const SizedBox.shrink();
              return _Carousel(
                title: 'Recently Played',
                children: recent.take(10).map((t) {
                  return ArtCard(
                    imageUrl: sizedThumb(t.thumbnail, ThumbnailSize.card),
                    title: t.title,
                    subtitle: t.artist,
                    onTap: () => pc.playWithRecommendations(
                      t.videoId,
                      title: t.title,
                      artist: t.artist,
                      thumbnail: t.thumbnail,
                      duration: t.durationValue,
                    ),
                  );
                }).toList(),
              );
            }),
          ),
          // ── Made For You (curated mixes) ─────────────────────────────
          SliverToBoxAdapter(
            child: Obx(() {
              if (home.loadingMixes.value && home.mixes.isEmpty) {
                return const _CarouselSkeleton(title: 'Made For You');
              }
              if (home.mixes.isEmpty) return const SizedBox.shrink();
              return _Carousel(
                title: 'Made For You',
                cardSize: 190,
                children: home.mixes.map((m) {
                  return ArtCard(
                    // mix.image is a saragama mood image — used as-is.
                    imageUrl: m.image,
                    title: m.title,
                    subtitle: '${m.trackCount} songs',
                    overline: 'MIX',
                    size: 190,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => MixDetailScreen(mix: m))),
                    // Long-press mirrors the track-row convention: quick
                    // actions without leaving the screen.
                    onLongPress: () => _showMixActions(context, m),
                  );
                }).toList(),
              );
            }),
          ),
          // ── Your Playlists ───────────────────────────────────────────
          SliverToBoxAdapter(child: _PlaylistsRow()),
          // ── Empty fallback for a brand-new install ──────────────────
          SliverToBoxAdapter(child: Obx(() {
            final blank = pc.searchHistory.isEmpty &&
                home.mixes.isEmpty &&
                !home.loadingMixes.value &&
                LibraryService.getPlaylists().isEmpty &&
                LibraryService.getLiked().isEmpty;
            if (!blank) return const SizedBox.shrink();
            return const Padding(
              padding: EdgeInsets.only(top: 60),
              child: EmptyState(
                icon: Icons.graphic_eq_rounded,
                title: 'Welcome to Gravity',
                message:
                    'Search for a song to start listening — your home will\nfill up with picks made just for you.',
              ),
            );
          })),
          SliverToBoxAdapter(
              child: SizedBox(height: bottomDockInset(context))),
        ],
      ),
    );
  }
}

class _PlaylistsRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final playlists = LibraryService.getPlaylists();
    if (playlists.isEmpty) return const SizedBox.shrink();
    return _Carousel(
      title: 'Your Playlists',
      children: playlists.map((pl) {
        return ArtCard(
          imageUrl: sizedThumb(pl.thumbnailUrl, ThumbnailSize.card),
          title: pl.name,
          subtitle: '${pl.tracks.length} songs',
          overline: 'PLAYLIST',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PlaylistDetailScreen(playlistId: pl.id))),
        );
      }).toList(),
    );
  }
}

/// Horizontal scrolling section with a header.
/// Quick actions for a "Made For You" mix: play or shuffle its whole track
/// list without opening the detail screen. Mixes carry their tracks inline, so
/// this needs no extra request.
void _showMixActions(BuildContext context, Mix mix) {
  final pc = Get.find<PlayerController>();
  final tracks = mix.tracks;

  void run(void Function(List<MediaItem>) play) {
    Navigator.pop(context);
    if (tracks.isEmpty) {
      Get.snackbar('Mix unavailable', 'This mix has no tracks right now.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: AppColors.card,
          colorText: AppColors.white,
          duration: const Duration(seconds: 2));
      return;
    }
    play(tracks.map((t) => t.toMediaItem()).toList());
  }

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetCtx) => GlassContainer(
      radius: AppRadius.xl,
      fill: AppColors.card.withOpacity(0.72),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHandle(),
            const SizedBox(height: 8),
            ListTile(
              title: Text(mix.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title(size: 15)),
              subtitle: Text('${mix.trackCount} songs',
                  style: AppText.subtitle(size: 13)),
            ),
            const Divider(height: 8, color: AppColors.glassBorder),
            ListTile(
              leading:
                  const Icon(Icons.play_arrow_rounded, color: Colors.white),
              title: Text('Play all', style: AppText.title(size: 15)),
              onTap: () => run(pc.playAllMedia),
            ),
            ListTile(
              leading: const Icon(Icons.shuffle_rounded, color: Colors.white),
              title: Text('Shuffle play', style: AppText.title(size: 15)),
              onTap: () => run(pc.playShuffledMedia),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Carousel extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final double cardSize;
  const _Carousel({
    required this.title,
    required this.children,
    this.cardSize = 150,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        SizedBox(
          height: cardSize + 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenMargin),
            itemCount: children.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.gutter),
            itemBuilder: (_, i) => children[i],
          ),
        ),
        const SizedBox(height: AppSpacing.stackMd),
      ],
    );
  }
}

class _CarouselSkeleton extends StatelessWidget {
  final String title;
  const _CarouselSkeleton({required this.title});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        SizedBox(
          height: 202,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.screenMargin),
            itemCount: 4,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.gutter),
            itemBuilder: (_, __) => Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.stackMd),
      ],
    );
  }
}
