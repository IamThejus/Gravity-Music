// ui/search/search_screen.dart
//
// Search backed by the real SearchService (/autocomplete). Recent searches
// come from PlayerController.searchHistory. Genre cards are not a fake API —
// each one simply runs a real autocomplete query for that term. Tapping a
// result plays it via playWithRecommendations and records it in history.

import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../../controllers/player_controller.dart';
import '../../services/album_service.dart';
import '../../services/search_service.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../theme/glass.dart';
import '../shell/responsive.dart';
import '../ui_helpers.dart';
import '../widgets/common_widgets.dart';
import 'album_detail_screen.dart';

// ── Controller ───────────────────────────────────────────────────────────────

class SearchUiController extends GetxController {
  final query = ''.obs;
  final results = <SearchResult>[].obs;
  final albums = <Album>[].obs;
  final loading = false.obs;
  Timer? _debounce;

  /// Owned here rather than built in SearchScreen.build() — a controller
  /// constructed during build is recreated on every rebuild, which drops the
  /// typed text. The FocusNode also lets Ctrl+F (global shortcuts) put the
  /// caret in this field from outside the widget tree.
  final textController = TextEditingController();
  final searchFocus = FocusNode();

  void onChanged(String value) {
    query.value = value;
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      results.clear();
      albums.clear();
      loading.value = false;
      return;
    }
    loading.value = true;
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(value));
  }

  /// Runs a query immediately (used by genre cards). Mirrors the term into the
  /// field so the search box reflects what's actually being shown.
  void runQuery(String value) {
    query.value = value;
    textController.text = value;
    _debounce?.cancel();
    loading.value = true;
    _run(value);
  }

  Future<void> _run(String value) async {
    // Songs and albums resolve independently — fetch both at once so the album
    // strip and the track list land together rather than serially.
    final res = await Future.wait([
      SearchService.autocomplete(value),
      AlbumService.search(value),
    ]);
    if (query.value.trim() != value.trim()) return; // superseded
    results.assignAll(res[0] as List<SearchResult>);
    albums.assignAll(res[1] as List<Album>);
    loading.value = false;
  }

  @override
  void onClose() {
    _debounce?.cancel();
    textController.dispose();
    searchFocus.dispose();
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

    void openAlbum(Album a) {
      AppHaptics.light();
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: a)));
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
                      controller: sc.textController,
                      focusNode: sc.searchFocus,
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
                            sc.textController.clear();
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
                final songs = sc.results;
                final albums = sc.albums;
                if (sc.loading.value && songs.isEmpty && albums.isEmpty) {
                  return const Center(
                      child: CircularProgressIndicator(color: Colors.white));
                }
                if (songs.isEmpty && albums.isEmpty) {
                  return const EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No results',
                    message: 'Try a different song or artist.',
                  );
                }
                // Albums strip (if any) sits above the song list, as a single
                // header item so the whole thing scrolls together.
                final hasAlbums = albums.isNotEmpty;
                return ListView.builder(
                  padding: EdgeInsets.only(bottom: bottomDockInset(context)),
                  itemCount: songs.length + (hasAlbums ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (hasAlbums && i == 0) {
                      return _AlbumStrip(albums: albums, onOpen: openAlbum);
                    }
                    final r = songs[i - (hasAlbums ? 1 : 0)];
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

// ── Albums strip (horizontal cards above the song results) ────────────────────

class _AlbumStrip extends StatelessWidget {
  final List<Album> albums;
  final void Function(Album) onOpen;
  const _AlbumStrip({required this.albums, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Albums'),
        SizedBox(
          height: 208,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenMargin),
            itemCount: albums.length,
            separatorBuilder: (_, __) =>
                const SizedBox(width: AppSpacing.gutter),
            itemBuilder: (_, i) =>
                _AlbumCard(album: albums[i], onTap: () => onOpen(albums[i])),
          ),
        ),
        const SizedBox(height: AppSpacing.stackMd),
      ],
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback onTap;
  const _AlbumCard({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 148,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArtImage(
                url: sizedThumb(album.thumbnail, ThumbnailSize.card),
                size: 148,
                radius: AppRadius.lg),
            const SizedBox(height: 8),
            Text(prettyTitle(album.title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.trackTitle(size: 14)),
            if (album.subtitle.isNotEmpty)
              Text(prettyTitle(album.subtitle),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.subtitle(size: 12.5)),
          ],
        ),
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
        const SectionHeader(title: 'Browse'),
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
              children: _genres
                  .map((g) => _GenreTile(
                        label: g.$1,
                        color: g.$2,
                        onTap: () => sc.runQuery(g.$1),
                      ))
                  .toList(),
            );
          }),
        ),
      ],
    );
  }
}

// ── Genre "Browse" tile ───────────────────────────────────────────────────────

/// A Browse tile that shows real artwork behind its genre gradient. The
/// gradient renders instantly (and stays as the fallback if art can't be
/// resolved); a representative thumbnail for the genre fades in once fetched.
class _GenreTile extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _GenreTile({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  State<_GenreTile> createState() => _GenreTileState();
}

class _GenreTileState extends State<_GenreTile> {
  String? _art;

  @override
  void initState() {
    super.initState();
    _art = _GenreArt.cached(widget.label);
    if (_art == null) {
      _GenreArt.resolve(widget.label).then((url) {
        if (mounted && url != null && url.isNotEmpty) {
          setState(() => _art = url);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Base genre gradient — the loading state and the fallback when no
            // artwork is available.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [widget.color, widget.color.withOpacity(0.4)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            // Artwork (fades in when resolved).
            if (_art != null)
              CachedNetworkImage(
                imageUrl: sizedThumb(_art!, ThumbnailSize.card),
                fit: BoxFit.cover,
                memCacheWidth: (260 * dpr).round(),
                fadeInDuration: const Duration(milliseconds: 350),
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            // Genre-tinted scrim so the label stays legible over any artwork.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    widget.color.withOpacity(0.30),
                    Colors.black.withOpacity(0.62),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(widget.label, style: AppText.heading(size: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Resolves + caches a representative thumbnail per genre. The first song
/// result for the genre term supplies the art; results are cached in-memory for
/// the session and in `CacheBox` for 24h so the Browse grid doesn't re-fetch.
class _GenreArt {
  static const _ttlMs = 24 * 60 * 60 * 1000; // 24h
  static final Map<String, String> _mem = {};
  static Box get _box => Hive.box('CacheBox');

  static String _key(String genre) => 'genreArt:$genre';

  /// A cached URL if present and fresh; null otherwise (triggers a fetch).
  static String? cached(String genre) {
    final m = _mem[genre];
    if (m != null) return m;
    final raw = _box.get(_key(genre)) as String?;
    if (raw == null) return null;
    try {
      final wrapper = jsonDecode(raw) as Map<String, dynamic>;
      final ts = wrapper['ts'] as int? ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > _ttlMs) return null;
      final url = wrapper['url'] as String?;
      if (url != null && url.isNotEmpty) _mem[genre] = url;
      return url;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> resolve(String genre) async {
    final hit = cached(genre);
    if (hit != null) return hit;
    try {
      final res = await SearchService.autocomplete(genre);
      final url = res.isNotEmpty ? res.first.thumbnail : null;
      if (url != null && url.isNotEmpty) {
        _mem[genre] = url;
        _box.put(
            _key(genre),
            jsonEncode({
              'url': url,
              'ts': DateTime.now().millisecondsSinceEpoch,
            }));
      }
      return url;
    } catch (_) {
      return null; // offline / parse failure → tile keeps its gradient
    }
  }
}
