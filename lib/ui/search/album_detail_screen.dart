// ui/search/album_detail_screen.dart
//
// Opens an album (from a search hit) as a playlist: hero header (cover, title,
// artist • year • N songs), Play / Shuffle, and the track list — mirroring
// MixDetailScreen. Unlike a Mix, an album search hit carries only its header,
// so the track list is resolved on open via AlbumService (24h cached) with a
// loading state. Playback is delegated to PlayerController (no logic here).

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/player_controller.dart';
import '../../services/album_service.dart';
import '../../services/thumb_util.dart';
import '../app_theme.dart';
import '../ui_helpers.dart';
import '../widgets/common_widgets.dart';
import '../widgets/mini_player.dart';

class AlbumDetailScreen extends StatefulWidget {
  final Album album;
  const AlbumDetailScreen({super.key, required this.album});

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  final _pc = Get.find<PlayerController>();
  AlbumDetail? _detail;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final detail = await AlbumService.getAlbum(widget.album.browseId);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _loading = false;
      _failed = detail == null || detail.tracks.isEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    // Header falls back to the search-hit metadata until the detail resolves.
    final title = _detail?.title.isNotEmpty == true ? _detail!.title : album.title;
    final artist =
        _detail?.artist.isNotEmpty == true ? _detail!.artist : album.artist;
    final year = _detail?.year.isNotEmpty == true ? _detail!.year : album.year;
    final cover =
        _detail?.thumbnail.isNotEmpty == true ? _detail!.thumbnail : album.thumbnail;
    final tracks = _detail?.tracks ?? const [];

    final metaParts = <String>[
      if (year.isNotEmpty) year,
      if (artist.isNotEmpty) artist,
      if (tracks.isNotEmpty) '${tracks.length} songs',
    ];

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: ScreenWithMiniPlayer(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              backgroundColor: AppColors.canvas,
              pinned: true,
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
                      ArtImage(
                          url: sizedThumb(cover, ThumbnailSize.card),
                          size: 150,
                          radius: AppRadius.lg),
                      const SizedBox(height: 12),
                      Text(prettyTitle(title),
                          style: AppText.heading(size: 24),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      if (metaParts.isNotEmpty)
                        Text(metaParts.join(' • '),
                            style: AppText.subtitle(size: 13),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                    child: CircularProgressIndicator(color: Colors.white)),
              )
            else if (_failed)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const EmptyState(
                        icon: Icons.album_rounded,
                        title: 'Album unavailable',
                        message: 'Could not load this album. Check your '
                            'connection and try again.',
                      ),
                      const SizedBox(height: AppSpacing.gutter),
                      SecondaryButton(
                          label: 'Retry',
                          icon: Icons.refresh_rounded,
                          onTap: _load),
                    ],
                  ),
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
                          onTap: () => _pc.playAllMedia(
                              tracks.map((t) => t.toMediaItem()).toList()),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.gutter),
                      Expanded(
                        child: SecondaryButton(
                          label: 'Shuffle',
                          icon: Icons.shuffle_rounded,
                          onTap: () => _pc.playShuffledMedia(
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
                      subtitle: t.artistLine,
                      trailingText: t.duration,
                      onTap: () => _pc.playAllMedia(
                          tracks.map((x) => x.toMediaItem()).toList(),
                          startIndex: i),
                    );
                  },
                  childCount: tracks.length,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          ],
        ),
      ),
    );
  }
}
