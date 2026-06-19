// ui/search/search_screen.dart
//
// Search backed by the real SearchService (/autocomplete). Recent searches
// come from PlayerController.searchHistory. Genre cards are not a fake API —
// each one simply runs a real autocomplete query for that term. Tapping a
// result plays it via playWithRecommendations and records it in history.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/player_controller.dart';
import '../../services/search_service.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../theme/glass.dart';
import '../shell/responsive.dart';
import '../ui_helpers.dart';
import '../widgets/common_widgets.dart';

// ── Controller ───────────────────────────────────────────────────────────────

class SearchUiController extends GetxController {
  final query = ''.obs;
  final results = <SearchResult>[].obs;
  final loading = false.obs;
  Timer? _debounce;

  void onChanged(String value) {
    query.value = value;
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      results.clear();
      loading.value = false;
      return;
    }
    loading.value = true;
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(value));
  }

  /// Runs a query immediately (used by genre cards).
  void runQuery(String value) {
    query.value = value;
    _debounce?.cancel();
    loading.value = true;
    _run(value);
  }

  Future<void> _run(String value) async {
    final res = await SearchService.autocomplete(value);
    if (query.value.trim() != value.trim()) return; // superseded
    results.assignAll(res);
    loading.value = false;
  }

  @override
  void onClose() {
    _debounce?.cancel();
    super.onClose();
  }
}

// ── Genre presets (each triggers a real search) ──────────────────────────────

const _genres = [
  ('Pop', Color(0xFF8E2DE2)),
  ('Hip-Hop', Color(0xFF232526)),
  ('Electronic', Color(0xFF0F2027)),
  ('Rock', Color(0xFF93291E)),
  ('Lofi', Color(0xFF42275A)),
  ('Romance', Color(0xFFCB356B)),
];

// ── Screen ───────────────────────────────────────────────────────────────────

class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sc = Get.put(SearchUiController());
    final pc = Get.find<PlayerController>();
    final controller = TextEditingController();

    void play(SearchResult r) {
      AppHaptics.light();
      pc.addToSearchHistory(r.toLibraryTrack());
      pc.playWithRecommendations(
        r.videoId,
        title: r.title,
        artist: r.artistLine,
        thumbnail: r.thumbnail,
        duration: r.durationValue,
      );
    }

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screenMargin, 16,
                AppSpacing.screenMargin, AppSpacing.gutter),
            child: Row(
              children: [
                Expanded(child: Text('Search', style: AppText.heading(size: 32))),
              ],
            ),
          ),
          // ── Glass search field ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenMargin),
            child: GlassContainer(
              radius: AppRadius.pill,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded,
                      color: AppColors.textTertiary, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      onChanged: sc.onChanged,
                      style: AppText.title(size: 15),
                      cursorColor: Colors.white,
                      decoration: InputDecoration(
                        isCollapsed: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 14),
                        border: InputBorder.none,
                        hintText: 'Artists, songs, or lyrics',
                        hintStyle: AppText.subtitle(size: 15),
                      ),
                    ),
                  ),
                  Obx(() => sc.query.value.isEmpty
                      ? const SizedBox.shrink()
                      : GestureDetector(
                          onTap: () {
                            controller.clear();
                            sc.onChanged('');
                          },
                          child: const Icon(Icons.close_rounded,
                              color: AppColors.textTertiary, size: 20),
                        )),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.gutter),
          Expanded(
            child: Obx(() {
              // Results view when a query is active.
              if (sc.query.value.trim().isNotEmpty) {
                if (sc.loading.value && sc.results.isEmpty) {
                  return const Center(
                      child: CircularProgressIndicator(color: Colors.white));
                }
                if (sc.results.isEmpty) {
                  return const EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No results',
                    message: 'Try a different song or artist.',
                  );
                }
                return ListView.builder(
                  padding: EdgeInsets.only(bottom: bottomDockInset(context)),
                  itemCount: sc.results.length,
                  itemBuilder: (_, i) {
                    final r = sc.results[i];
                    return TrackTile(
                      imageUrl: sizedThumb(r.thumbnail, ThumbnailSize.tile),
                      title: r.title,
                      subtitle: r.artistLine,
                      trailingText: r.duration,
                      onTap: () => play(r),
                    );
                  },
                );
              }
              // Idle view: recent searches + genres.
              return _IdleView(sc: sc, onPlay: play);
            }),
          ),
        ],
      ),
    );
  }
}

class _IdleView extends StatelessWidget {
  final SearchUiController sc;
  final void Function(SearchResult) onPlay;
  const _IdleView({required this.sc, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final pc = Get.find<PlayerController>();
    return ListView(
      padding: EdgeInsets.only(bottom: bottomDockInset(context)),
      children: [
        Obx(() {
          final recent = pc.searchHistory;
          if (recent.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.screenMargin, 0,
                    AppSpacing.screenMargin, 8),
                child: Row(
                  children: [
                    Expanded(
                        child: Text('Recent Searches',
                            style: AppText.heading(size: 20))),
                    GestureDetector(
                      onTap: pc.clearSearchHistory,
                      child: Text('Clear',
                          style: AppText.caption(
                              color: AppColors.textSecondaryHi)),
                    ),
                  ],
                ),
              ),
              ...recent.take(6).map((t) => TrackTile(
                    imageUrl: sizedThumb(t.thumbnail, ThumbnailSize.tile),
                    title: t.title,
                    subtitle: t.artist,
                    trailing: const Icon(Icons.north_west_rounded,
                        color: AppColors.textTertiary, size: 18),
                    onTap: () => pc.playWithRecommendations(
                      t.videoId,
                      title: t.title,
                      artist: t.artist,
                      thumbnail: t.thumbnail,
                      duration: t.durationValue,
                    ),
                  )),
              const SizedBox(height: AppSpacing.stackMd),
            ],
          );
        }),
        SectionHeader(title: 'Browse'),
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.screenMargin),
          child: LayoutBuilder(builder: (context, c) {
            return GridView.count(
              crossAxisCount: gridColumns(c.maxWidth),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: AppSpacing.gutter,
              mainAxisSpacing: AppSpacing.gutter,
              childAspectRatio: 1.7,
              children: _genres.map((g) {
                return GestureDetector(
                  onTap: () => sc.runQuery(g.$1),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [g.$2, g.$2.withOpacity(0.4)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    alignment: Alignment.bottomLeft,
                    child: Text(g.$1, style: AppText.heading(size: 18)),
                  ),
                );
              }).toList(),
            );
          }),
        ),
      ],
    );
  }
}
