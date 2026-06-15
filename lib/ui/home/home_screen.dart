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
import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../services/library_service.dart';
import '../../services/mixes_service.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../library/library_screen.dart';
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
      mixes.assignAll(
          await MixesService.getMixes(forceRefresh: forceRefresh));
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
          const SliverToBoxAdapter(
              child: SizedBox(height: AppSpacing.bottomDock)),
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
